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
                f"Upstream attempt {attempt}/{UPSTREAM_ATTEMPTS} to {target_url} failed: {e}"
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

    try:
        resp = _forward(
            request.method,
            target_url,
            headers,
            request.get_data(),
            request.args
        )

        response_headers = [
            (k, v) for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP_HEADERS
        ]

        logger.info(f"Proxied {request.method} {request.path} -> {target_url} [Status: {resp.status_code}]")
        return Response(resp.content, status=resp.status_code, headers=response_headers)

    except requests.exceptions.RequestException as e:
        logger.error(f"Error forwarding request to inventory service at {target_url}: {e}")
        return jsonify({"error": f"Inventory service unavailable: {str(e)}"}), 502


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
        logger.error(f"Failed to queue billing message: {describe_error(e)}")
        return jsonify({"error": f"Failed to submit order to queue: {describe_error(e)}"}), 500