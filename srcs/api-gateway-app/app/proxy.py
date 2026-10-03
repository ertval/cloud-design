import os
import time
import logging
import requests
from flask import Blueprint, request, Response, jsonify
from app.queue_sender import RabbitMQSender, describe_error

logger = logging.getLogger(__name__)
proxy_bp = Blueprint("proxy", __name__)
sender = RabbitMQSender()

INVENTORY_HOST = os.getenv("INVENTORY_APP_HOST", "").strip() or "inventory-app"
INVENTORY_PORT = os.getenv("INVENTORY_APP_PORT", "").strip() or "8080"

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
    "cookie"
}

UPSTREAM_ATTEMPTS = 3
UPSTREAM_TIMEOUT = 10

# Client-facing copy for a dependency that cannot serve the request. These are
# deliberately fixed strings with NO interpolated exception, host or port: the
# internal topology (`inventory-app:8080`, `rabbit-queue`) is exactly what a
# client should not learn, and `requests`/pika/psycopg2 error strings are full
# of it. The detail goes to the log line next to it, which is where an operator
# needs it.
DEPENDENCY_UNAVAILABLE_ERROR = (
    "Upstream service is temporarily unavailable. Please retry shortly."
)
BROKER_UNAVAILABLE_ERROR = (
    "The order could not be queued because the messaging service is unavailable. "
    "Please retry shortly."
)


def _upstream_5xx(response):
    """True when an upstream 5xx must be re-labelled as a gateway 503.

    A 5xx from a dependency means *that* service failed, not that this gateway
    has a bug. Relaying it verbatim would (a) tell an operator our code is
    broken, (b) pollute the 5XX error budget and 5XX alarms, and (c) hand the
    client the upstream's raw error page - which for a database outage is a
    waitress HTML page and, further down, a traceback. 4xx is relayed unchanged:
    a client error is the client's, not a dependency outage.
    """
    return response.status_code >= 500


def _sanitise_subpath(subpath: str) -> str | None:
    """Reject traversal or encoded-separator payloads before building a URL.

    `subpath` reaches the upstream URL verbatim, so `..`, `%2e%2e` or a nested
    separator would let a client walk out of `/api/movies` and forge requests
    against the internal service.
    """
    if not subpath:
        return ""
    lowered = subpath.lower()
    if "\\" in subpath or "%" in subpath or ".." in subpath:
        return None
    if "//" in subpath or any(seg == "" for seg in subpath.split("/")):
        return None
    if lowered.startswith("/") or lowered.endswith("/"):
        return None
    if any(ch.isspace() for ch in subpath):
        return None
    # C0/C7 control characters, NUL above all. They are never legitimate in a
    # path segment: they are how request-smuggling and parser-confusion tricks
    # start, and `requests` percent-encodes them into the upstream request line.
    # Without this, `/api/movies/1%00` reached inventory-app, which answered 500
    # - a client error reported as a server fault.
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in subpath):
        return None
    return subpath


def _forward(method, target_url, headers, body, query):
    """Issue the upstream call with bounded retries on transient failures.

    Retries are safe for idempotent methods or on early connection establishment
    failures before data has been read by upstream.
    """
    last_error = None
    for attempt in range(1, UPSTREAM_ATTEMPTS + 1):
        try:
            return requests.request(
                method=method,
                url=target_url,
                headers=headers,
                params=query,
                data=body,
                allow_redirects=False,
                timeout=UPSTREAM_TIMEOUT
            )
        except requests.exceptions.RequestException as e:
            last_error = e
            logger.warning(
                f"Upstream attempt {attempt}/{UPSTREAM_ATTEMPTS} to {target_url} failed: "
                f"{describe_error(e)}"
            )
            # Only retry connection errors or idempotent methods (do not retry read timeouts on POST)
            is_idempotent = method.upper() in {"GET", "HEAD", "OPTIONS", "PUT", "DELETE"}
            is_conn_error = isinstance(e, requests.exceptions.ConnectionError)
            if not is_idempotent and not is_conn_error:
                break
            if attempt < UPSTREAM_ATTEMPTS:
                time.sleep(attempt)
    raise last_error


@proxy_bp.route("/api/movies", methods=["GET", "POST", "PUT", "DELETE"], strict_slashes=False)
@proxy_bp.route("/api/movies/<path:subpath>", methods=["GET", "POST", "PUT", "DELETE"], strict_slashes=False)
def proxy_movies(subpath=""):
    safe_subpath = _sanitise_subpath(subpath)
    if safe_subpath is None:
        return jsonify({"error": "Invalid path segment"}), 400

    target_url = f"http://{INVENTORY_HOST}:{INVENTORY_PORT}/api/movies"
    if safe_subpath:
        target_url = f"{target_url}/{safe_subpath}"

    headers = {k: v for k, v in request.headers if k.lower() not in HOP_BY_HOP_HEADERS}
    headers["Host"] = f"{INVENTORY_HOST}:{INVENTORY_PORT}"
    headers["X-Forwarded-For"] = request.remote_addr or ""
    headers["X-Forwarded-Proto"] = request.scheme
    headers["X-Forwarded-Host"] = request.host

    # Read the body BEFORE the try: an over-long body raises Flask's
    # RequestEntityTooLarge, which must surface as the 413 it is rather than be
    # folded into the dependency-unavailable path below.
    request_body = request.get_data()

    try:
        resp = _forward(
            request.method,
            target_url,
            headers,
            request_body,
            request.args
        )
    except requests.exceptions.RequestException as e:
        # Connection refused, DNS failure, read timeout: the inventory service
        # could not be reached. 503, not 500 and not 502 - the request is
        # retryable and no application logic failed. The detail (including the
        # internal host and port) stays in the log.
        logger.error(
            f"Inventory service at {target_url} could not be reached after "
            f"{UPSTREAM_ATTEMPTS} attempts for {request.method} {request.path}: "
            f"{describe_error(e)}"
        )
        return jsonify({"error": DEPENDENCY_UNAVAILABLE_ERROR}), 503

    if _upstream_5xx(resp):
        # The upstream failed (typically because ITS database is down). Report
        # that as 503 with our own body rather than relaying its error page,
        # which leaks both the internal hostname and a traceback.
        logger.error(
            f"Inventory service at {target_url} returned {resp.status_code} for "
            f"{request.method} {request.path}; surfacing 503 to the client. "
            f"Upstream body: {resp.text[:512]!r}"
        )
        return jsonify({"error": DEPENDENCY_UNAVAILABLE_ERROR}), 503

    response_headers = [
        (k, v) for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP_HEADERS
    ]

    logger.info(f"Proxied {request.method} {request.path} -> {target_url} [Status: {resp.status_code}]")
    return Response(resp.content, status=resp.status_code, headers=response_headers)


@proxy_bp.route("/api/billing", methods=["POST"], strict_slashes=False)
@proxy_bp.route("/api/billing/", methods=["POST"], strict_slashes=False)
def create_billing_order():
    data = request.get_json(force=True, silent=True)
    if not data or not isinstance(data, dict):
        return jsonify({"error": "Valid JSON body is required"}), 400

    raw_body = request.get_data(as_text=True).strip()

    try:
        sender.publish_message(raw_body)
        logger.info(f"Billing message enqueued: {raw_body}")
        return jsonify({"message": f"{raw_body} sent"}), 200
    except Exception as e:
        # The broker is a dependency: unreachable, refusing or unroutable is a
        # 503 the client may retry, not a 500 that blames this service. The
        # response body is a fixed string because pika's error text contains the
        # broker hostname ("[Errno -2] Name does not resolve" names it once
        # resolved), which must not be resolved client-side.
        logger.error(f"Failed to queue billing message: {describe_error(e)}")
        return jsonify({"error": BROKER_UNAVAILABLE_ERROR}), 503