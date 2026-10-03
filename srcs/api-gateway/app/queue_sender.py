import os
import ssl
import time
import logging
import pika

logger = logging.getLogger(__name__)

# =============================================================================
# AMQPS / TLS - ONE rule, implemented identically in
#   srcs/api-gateway/app/queue_sender.py  (publisher)
#   srcs/billing-app/app/consume_queue.py    (consumer)
# The publisher and the consumer MUST agree on the connection mode: a plaintext
# publisher against a TLS-only broker drops orders, and a plaintext consumer
# against the same broker reconnects forever. Both files therefore derive the
# mode from the same rule and the same environment variables.
#
#   TLS is ON  if  RABBITMQ_TLS is explicitly truthy ("1"/"true"/"yes"/"on"),
#               OR RABBITMQ_TLS is unset/blank AND the target implies TLS:
#                   * the effective port is 5671 (the AMQPS port), OR
#                   * RABBITMQ_HOST carried an "amqps://" scheme.
#
#   TLS is OFF if  RABBITMQ_TLS is explicitly falsy ("0"/"false"/"no"/"off"),
#               OR the target does not imply TLS.
#
# Why 5671 is the load-bearing signal: terraform/amazon_mq.tf strips the scheme
# and the port off the AWS endpoint, so on ECS RABBITMQ_HOST is a BARE hostname
# (b-xxxx.mq.<region>.amazonaws.com) and RABBITMQ_PORT=5671 is the only signal
# left to detect. Amazon MQ for RabbitMQ has NO plaintext listener at all, so
# without this rule every publish fails on a TLS handshake against a plaintext
# AMQP greeting - which is the cross-team blocker this fixes.
#
# Locally (docker-compose.yml) RABBITMQ_HOST=rabbit-queue, RABBITMQ_PORT=5672
# and RABBITMQ_TLS is unset, so the rule resolves to plaintext 5672 and the
# local stack behaves exactly as it did before.
#
# Certificate verification is ON unless RABBITMQ_TLS_VERIFY is explicitly
# falsy - see build_ssl_options(). Disabling it by default would reintroduce
# the very defect this change exists to fix.
# =============================================================================

DEFAULT_AMQP_PORT = 5672
AMQPS_PORT = 5671            # the only listener Amazon MQ for RabbitMQ provides
_TRUTHY = frozenset({"1", "true", "yes", "on"})
_FALSY = frozenset({"0", "false", "no", "off"})

# NOTE: PUBLISH_* budgets are defined AFTER the _env_* helpers below (not
# here) so garbage values like RABBITMQ_SOCKET_TIMEOUT=abc fall back with a
# warning instead of raising ValueError at import time.


def _require_env(name: str) -> str:
    """Return required secret env var or raise (no hardcoded fallback for secrets)."""
    value = os.getenv(name)
    if not value:
        raise RuntimeError(
            f"Missing required secret environment variable: {name}. "
            "Set it via .env / compose environment (see .env.example)."
        )
    return value.strip()


def _env_or_default(name: str, default: str) -> str:
    """Non-secret setting with a safe default.

    `os.getenv(name, default)` is not enough: Docker Compose interpolates an
    *undefined* variable as an empty string rather than leaving it unset, so a
    missing or partial `.env` would yield `""` and defeat the default.
    """
    value = os.getenv(name)
    if value is None or not value.strip():
        return default
    return value.strip()


def _env_port(name: str, default: int) -> int:
    """Non-secret port with a safe default, tolerant of empty/blank values."""
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw.strip())
    except ValueError:
        logger.warning(f"Invalid value for {name}={raw!r}; falling back to {default}.")
        return default


def _env_flag(name: str) -> bool | None:
    """Three-state flag: True, False, or None when unset/blank/unrecognised.

    None is deliberately distinct from False. It is what lets auto-detection
    tell "the operator explicitly said no TLS" apart from "the operator said
    nothing", which is the difference between honouring RABBITMQ_TLS=false and
    falling back to the port heuristic.
    """
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return None
    value = raw.strip().lower()
    if value in _TRUTHY:
        return True
    if value in _FALSY:
        return False
    logger.warning(
        f"Ignoring unrecognised value {raw!r} for {name}; "
        f"expected one of {sorted(_TRUTHY | _FALSY)}. Falling back to auto-detection."
    )
    return None


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw.strip())
    except ValueError:
        logger.warning(f"Invalid value for {name}={raw!r}; falling back to {default}.")
        return default


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw.strip())
    except ValueError:
        logger.warning(f"Invalid value for {name}={raw!r}; falling back to {default}.")
        return default


# =============================================================================
# Bounded publish budget - one POST /api/billing must fail fast, never hang.
# Defaults: RABBITMQ_SOCKET_TIMEOUT=3, RABBITMQ_PUBLISH_MAX_RETRIES=2,
#           RABBITMQ_RETRY_DELAY=1.
# Worst-case wall time for publish_message():
#     max_retries * socket_timeout + (max_retries - 1) * retry_delay
#   = 2 * 3s + 1 * 1s = ~7s socket-bound (+ small AMQP handshake overhead).
# DNS-down is slower: Docker's embedded DNS burns ~5s resolver timeout per
# attempt, measured live at ~10s total (see docs/AUDIT_GUIDE.md §8.5) —
# still bounded, not hung, and the read path is unaffected.
# That stays well under the edge timeouts (nginx proxy_read_timeout 60s in
# docker-compose.yml; waitress has no request timeout; the inventory upstream
# path uses UPSTREAM_TIMEOUT=10s), so a dead broker surfaces as a prompt
# HTTP 500 instead of a hung client.
# Tradeoff vs play (5 retries / socket 5s / connection_attempts 3 with linear
# backoff, worst case ~30s+): the smaller budget is LESS resilient to a
# transient broker blip and will 500 where play would eventually succeed, but
# it is what keeps the gateway's fast-200/500 contract. Do NOT raise these
# without also raising the gateway/client timeouts above - a larger budget
# just turns a dead broker into a hung request.
# Each value is tolerant of garbage (e.g. "abc"): invalid input logs a
# warning and falls back to the default instead of crashing at import.
# =============================================================================
PUBLISH_SOCKET_TIMEOUT = _env_float("RABBITMQ_SOCKET_TIMEOUT", 3.0)
PUBLISH_MAX_RETRIES = _env_int("RABBITMQ_PUBLISH_MAX_RETRIES", 2)
PUBLISH_RETRY_DELAY = _env_float("RABBITMQ_RETRY_DELAY", 1.0)


def _resolve_amqp_target(raw_host: str, port: int) -> tuple[str, int, bool]:
    """Normalise RABBITMQ_HOST / RABBITMQ_PORT into (host, port, scheme_is_tls).

    pika wants a bare hostname and an integer port. Handing it
    "amqps://broker:5671" fails as a DNS lookup error rather than a TLS error,
    which hides the real fault, so the scheme is stripped here. A port carried
    inside the URL is adopted rather than ignored: silently connecting to 5672
    when the operator wrote 5671 is exactly the failure being fixed.
    """
    host = raw_host.strip()
    scheme_is_tls = host.lower().startswith("amqps://")
    if "://" in host:
        host = host.split("://", 1)[1]

    # Split a trailing ":port" off the host, leaving a bracketed IPv6 literal
    # such as "[::1]:5671" intact - a naive rpartition(":") would corrupt it.
    port_in_host: str | None = None
    if host.startswith("["):
        literal, bracket, remainder = host.partition("]")
        if remainder.startswith(":"):
            host, port_in_host = literal + bracket, remainder[1:]
    elif host.count(":") == 1:
        candidate_host, _, candidate_port = host.partition(":")
        if candidate_port.strip().isdigit():
            host, port_in_host = candidate_host, candidate_port.strip()

    if port_in_host:
        port = int(port_in_host)
    return host, port, scheme_is_tls


def tls_enabled_for(raw_host: str, port: int) -> bool:
    """Return the connection mode from THE rule documented at the top of this file.

    Explicit RABBITMQ_TLS wins in both directions; when it is absent the target
    decides, so an operator only has to set the host and port that Terraform
    already injects.
    """
    _, effective_port, scheme_is_tls = _resolve_amqp_target(raw_host, port)
    override = _env_flag("RABBITMQ_TLS")
    if override is not None:
        return override
    return scheme_is_tls or effective_port == AMQPS_PORT


def build_ssl_options(host: str) -> pika.SSLOptions:
    """Build `pika.SSLOptions` with certificate verification ENABLED.

    * `ssl.create_default_context()` yields check_hostname=True and
      verify_mode=CERT_REQUIRED, so an expired, self-signed or wrong-name
      certificate is rejected. That is what keeps the AMQP password and the
      queued orders confidential and untamperable in transit.
    * `RABBITMQ_CA_FILE` supplies a private/self-signed CA bundle for a broker
      that no public authority vouches for. It REPLACES the default trust
      store, so it must contain every CA the broker may present. Leave it unset
      on AWS: an Amazon MQ certificate chains to the public Amazon Trust
      Services CA, which the system store already contains.
    * `pika.SSLOptions(context, host)` puts the broker hostname into SNI and
      into the certificate hostname check, so TLS cannot succeed against a
      certificate issued for a different name.
    * `RABBITMQ_TLS_VERIFY` is the only opt-out and it is INSECURE: with it
      falsy, check_hostname and verify_mode are both cleared, so ANY certificate
      from ANY holder is accepted and an attacker can impersonate the broker,
      read the credentials and read or alter queued orders. Off by default; for
      a throwaway lab broker with a self-signed cert only.
    """
    ca_file = os.getenv("RABBITMQ_CA_FILE")
    ca_file = ca_file.strip() if ca_file and ca_file.strip() else None
    if ca_file is not None and not os.path.isfile(ca_file):
        # Raised, not warned: an unreadable CA bundle would otherwise surface
        # later as an opaque "certificate verify failed" on the first publish.
        raise RuntimeError(
            f"RABBITMQ_CA_FILE points at {ca_file!r}, which is not a readable file. "
            "Mount the CA bundle into the container or unset the variable to use "
            "the system trust store (see .env.example)."
        )
    # cafile=None loads the platform default CA store; a supplied cafile
    # REPLACES it, so the bundle must contain the full chain the broker may
    # present.
    context = ssl.create_default_context(cafile=ca_file)

    if _env_flag("RABBITMQ_TLS_VERIFY") is False:
        logger.warning(
            "INSECURE: RABBITMQ_TLS_VERIFY is falsy, so the broker certificate "
            "and hostname are NOT verified. Any man-in-the-middle can impersonate "
            "the broker and read the AMQP credentials and queued orders. Use only "
            "against a local test broker with a self-signed certificate."
        )
        # check_hostname must be cleared BEFORE verify_mode: Python refuses
        # verify_mode=CERT_NONE while check_hostname is still True.
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    logger.info(
        f"TLS enabled for {host}: context={context.__class__.__name__} "
        f"check_hostname={context.check_hostname} verify_mode={context.verify_mode} "
        f"ca_file={ca_file or 'system default'}"
    )
    return pika.SSLOptions(context, host)


def ssl_options_for(raw_host: str, port: int) -> pika.SSLOptions | None:
    """Return SSLOptions for an AMQPS target, or None for plaintext AMQP.

    None is the signal pika itself uses for "no TLS", so returning it (rather
    than a disabled context) is what keeps the plaintext path
    behaviour-identical to the pre-TLS path except for the bounded
    connection/publish timeouts.
    """
    host, _, _ = _resolve_amqp_target(raw_host, port)
    if not tls_enabled_for(raw_host, port):
        return None
    return build_ssl_options(host)


def describe_error(exc):
    """Render an exception usefully.

    Pika's AMQP errors frequently have an EMPTY str(), which used to produce
    client responses like "Failed to submit order to queue: Could not publish
    message to RabbitMQ: " with no diagnostic whatsoever.
    """
    text = str(exc).strip()
    detail = text or exc.__class__.__name__
    cause = getattr(exc, "__cause__", None) or getattr(exc, "__context__", None)
    if cause is not None and str(cause).strip():
        detail = f"{detail} (caused by {cause.__class__.__name__}: {cause})"
    return detail


class RabbitMQSender:
    def __init__(self):
        # Non-secrets keep safe defaults; secrets MUST come from env.
        raw_host = _env_or_default("RABBITMQ_HOST", "rabbit-queue")
        raw_port = _env_port("RABBITMQ_PORT", DEFAULT_AMQP_PORT)
        self.user = _require_env("RABBITMQ_USER")
        self.password = _require_env("RABBITMQ_PASSWORD")
        self.queue = _env_or_default("RABBITMQ_QUEUE", "billing_queue")
        # Resolved once, here, so a bad TLS configuration (an unreadable CA
        # bundle, say) fails at construction with a named error instead of
        # turning every POST /api/billing into an opaque "certificate verify
        # failed" retry storm.
        self.host, self.port, _ = _resolve_amqp_target(raw_host, raw_port)
        self.ssl_options = ssl_options_for(raw_host, raw_port)
        logger.info(
            f"RabbitMQ sender configured: {self.host}:{self.port} queue='{self.queue}' "
            f"user='{self.user}' tls={'on' if self.ssl_options else 'off'}"
        )

    def _get_connection(self):
        credentials = pika.PlainCredentials(self.user, self.password)
        parameters = pika.ConnectionParameters(
            host=self.host,
            port=self.port,
            credentials=credentials,
            # None means plaintext AMQP; an SSLOptions instance switches pika to
            # an AMQPS handshake with verification. Built from RABBITMQ_TLS /
            # RABBITMQ_PORT - see the rule at the top of this file.
            ssl_options=self.ssl_options,
            # A single connection attempt with no retry_delay: the retry budget
            # is owned by publish_message(), which needs to stay bounded so a
            # dead broker fails fast instead of hanging the HTTP request.
            connection_attempts=1,
            retry_delay=0,
            socket_timeout=PUBLISH_SOCKET_TIMEOUT,
            blocked_connection_timeout=PUBLISH_SOCKET_TIMEOUT,
            heartbeat=60
        )
        return pika.BlockingConnection(parameters)

    def publish_message(self, message: str, max_retries: int = None, backoff: float = None) -> bool:
        """Publish a durable, persistent message with publisher confirms.

        `channel.confirm_delivery()` turns AMQP acknowledgements into synchronous
        guarantees, so a returned `True` means "the broker accepted and persisted
        the message", not merely "the bytes reached a socket". `mandatory=True`
        plus a return callback makes an unroutable message a hard failure instead
        of a silently dropped one.

        Retries are bounded by PUBLISH_MAX_RETRIES / PUBLISH_SOCKET_TIMEOUT so
        the caller gets a prompt failure instead of a request that hangs for
        over a minute while the broker is down.
        """
        if max_retries is None:
            max_retries = PUBLISH_MAX_RETRIES
        if backoff is None:
            backoff = PUBLISH_RETRY_DELAY
        last_exception = None
        for attempt in range(1, max_retries + 1):
            connection = None
            try:
                connection = self._get_connection()
                channel = connection.channel()
                channel.confirm_delivery()
                # durable=True + delivery_mode=Persistent below are what make
                # the order survive a broker restart and a consumer outage.
                channel.queue_declare(queue=self.queue, durable=True)
                returned = []

                def _on_returned(channel_, method, properties, body):
                    returned.append(method.routing_key)

                channel.add_on_return_callback(_on_returned)
                channel.basic_publish(
                    exchange="",
                    routing_key=self.queue,
                    body=message.encode("utf-8"),
                    properties=pika.BasicProperties(
                        delivery_mode=pika.DeliveryMode.Persistent,
                        content_type="application/json"
                    ),
                    mandatory=True
                )
                if returned:
                    raise RuntimeError(
                        f"Message was returned as unroutable (routing_key={returned[0]!r})"
                    )
                logger.info(f"Published message to queue '{self.queue}' on attempt {attempt}: {message}")
                return True
            except Exception as e:
                last_exception = e
                logger.warning(
                    f"RabbitMQ publish attempt {attempt}/{max_retries} failed: {describe_error(e)}"
                )
                # No sleep after the final attempt - there is nothing to wait for.
                if attempt < max_retries:
                    time.sleep(backoff)
            finally:
                if connection is not None and connection.is_open:
                    try:
                        connection.close()
                    except Exception:
                        pass

        logger.error(f"Failed to publish message after {max_retries} attempts: {describe_error(last_exception)}")
        raise RuntimeError(f"Could not publish message to RabbitMQ: {describe_error(last_exception)}")
