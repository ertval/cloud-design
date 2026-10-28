import os
import ssl
import json
import time
import logging
import signal
import threading
import pika
from app.orders import Order
from app.validation import InvalidOrderError, coerce_order_payload

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
# without this rule this consumer would reconnect in a loop forever against a
# plaintext AMQP greeting and no order would ever reach PostgreSQL.
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


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return float(raw.strip())
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


# Pause before requeueing a message whose database write failed. With
# prefetch_count=1 this is what turns a database outage into a slow retry
# loop instead of a hot spin.
REDELIVERY_BACKOFF_SECONDS = _env_float("REDELIVERY_BACKOFF_SECONDS", 5.0)


class _ShutdownWatchdog:
    """Wakes a consumer that is blocked inside `channel.start_consuming()`.

    `start_consuming()` parks this thread in the AMQP socket read and never looks
    at `stop_event`, so a shutdown has to be turned into a `stop_consuming()` call
    through pika's thread-safe callback mechanism.

    THE BUG THIS REPLACES: the thread that did that was created INSIDE the
    connection loop, a few lines above the blocking call. A SIGTERM landing in
    that window set `stop_event` with no watcher alive to act on it, so
    `start_consuming()` blocked forever, the process burned the whole 20 s grace
    period and Docker SIGKILLed it (exit 137) instead of exiting 0.

    The ordering here removes the window instead of narrowing it:

      * ONE watchdog is started before the loop, so it always exists. There is
        no longer a moment in which a connection is live and unwatched.
      * `set_active()` publishes the (connection, channel) pair BEFORE
        `start_consuming()` is called, and it takes the lock, so the watcher can
        never observe a half-published channel.
      * `set_active()` also re-checks `stop_event` under the lock, which closes
        the other direction: a stop that happened while the connection was being
        established is acted upon immediately instead of being lost.
      * `start_consuming()` is additionally guarded by an explicit
        `stop_event.is_set()` check, so a pre-set event can never reach the
        blocking call.

    The thread is a daemon, so it can never keep the process alive.
    """

    def __init__(self, stop_event):
        self._stop_event = stop_event
        self._lock = threading.Lock()
        self._active = None

    def start(self):
        threading.Thread(
            target=self._run,
            daemon=True,
            name="BillingQueueShutdownWatcher",
        ).start()

    def set_active(self, connection, channel):
        """Publish the channel the consumer is about to block on."""
        with self._lock:
            self._active = (connection, channel)
            already_stopping = self._stop_event.is_set()
        if already_stopping:
            logger.info("Shutdown already requested; stopping the consumer without entering start_consuming().")
            self._stop_now()

    def clear_active(self):
        with self._lock:
            self._active = None

    def _run(self):
        self._stop_event.wait()
        self._stop_now()

    def _stop_now(self):
        with self._lock:
            active = self._active
        if active is None:
            # Nothing is blocked on the AMQP socket: the reconnect loop's
            # `while not stop_event.is_set()` guard is what ends the loop.
            logger.info("Shutdown requested while no AMQP channel was open; nothing to interrupt.")
            return
        connection, channel = active
        logger.info("Shutdown requested; closing the AMQP channel to unblock start_consuming().")
        try:
            connection.add_callback_threadsafe(channel.stop_consuming)
        except Exception as e:  # pragma: no cover - connection already gone
            logger.debug(f"Could not schedule stop_consuming: {e}")


def start_consuming(db_session_factory, stop_event=None, connected_event=None):
    """Consume billing orders from RabbitMQ until `stop_event` is set.

    The consumer runs as PID 1's worker thread. On SIGTERM the process must stop
    cleanly: leaving `stop_event` unset means the loop never terminates, Docker
    waits out its 10 s grace period and SIGKILLs the container (exit 137).

    `connected_event`, when given, is set while the broker has this consumer
    registered on the queue and cleared as soon as it is not (connection lost,
    channel closed, shutdown). /ready reads it (app/__init__.py), so a task that
    has lost the broker no longer reports itself ready while consuming nothing.
    """
    if stop_event is None:
        stop_event = threading.Event()
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGTERM, signal.SIGINT):
                signal.signal(sig, lambda *_: (
                    logger.info("Shutdown signal received; stopping queue consumer"),
                    stop_event.set(),
                ))
        else:
            # signal.signal() is only legal on the main thread; raising here
            # would abort the consumer thread on a silent path.
            logger.warning(
                "start_consuming() was called from a non-main thread without a "
                "stop_event, so it cannot install signal handlers itself. Pass a "
                "threading.Event() from the main thread so SIGTERM is honoured."
            )

    # Non-secrets keep safe defaults; secrets MUST come from env.
    raw_host = _env_or_default("RABBITMQ_HOST", "rabbit-queue")
    raw_port = _env_port("RABBITMQ_PORT", DEFAULT_AMQP_PORT)
    rabbitmq_user = _require_env("RABBITMQ_USER")
    rabbitmq_password = _require_env("RABBITMQ_PASSWORD")
    queue_name = _env_or_default("RABBITMQ_QUEUE", "billing_queue")

    # Resolved once, before the loop: an unreadable CA bundle must fail loudly
    # here rather than as a reconnect loop that silently consumes no orders.
    rabbitmq_host, rabbitmq_port, _ = _resolve_amqp_target(raw_host, raw_port)
    ssl_options = ssl_options_for(raw_host, raw_port)

    credentials = pika.PlainCredentials(rabbitmq_user, rabbitmq_password)
    parameters = pika.ConnectionParameters(
        host=rabbitmq_host,
        port=rabbitmq_port,
        credentials=credentials,
        # None means plaintext AMQP; an SSLOptions instance switches pika to an
        # AMQPS handshake with verification. Derived from RABBITMQ_TLS /
        # RABBITMQ_PORT by the rule at the top of this file, which the gateway
        # applies identically - a mismatch here is what silently loses orders.
        ssl_options=ssl_options,
        heartbeat=60,
        blocked_connection_timeout=300
    )

    logger.info(
        f"Billing consumer starting up. Target queue: {queue_name} on "
        f"{rabbitmq_host}:{rabbitmq_port} tls={'on' if ssl_options else 'off'}"
    )

    # Started BEFORE the first connection attempt, so it outlives every
    # reconnect and no connection can ever be live without a watcher.
    watchdog = _ShutdownWatchdog(stop_event)
    watchdog.start()

    while not stop_event.is_set():
        connection = None
        try:
            logger.info("Attempting connection to RabbitMQ broker...")
            connection = pika.BlockingConnection(parameters)
            # The connect above can block for seconds. A SIGTERM during it must
            # not be followed by an immediate block in start_consuming().
            if stop_event.is_set():
                logger.info("Shutdown requested while connecting; not opening a channel.")
                break
            channel = connection.channel()

            # Ensure the queue is durable
            channel.queue_declare(queue=queue_name, durable=True)
            channel.basic_qos(prefetch_count=1)

            logger.info(f"Connected to RabbitMQ. Waiting for billing messages on '{queue_name}'...")

            def _handle_message(ch, method, body):
                """Parse, validate and persist one delivery.

                Acknowledgement policy (this is what guarantees at-least-once):
                  * ack   -> the order is durably committed to PostgreSQL, OR the
                             payload is a permanent poison message (non-JSON /
                             missing user_id) that can never succeed.
                  * nack  -> the database could not be written, or shutdown was
                             requested mid-flight. The message goes back on the
                             queue so it is retried once the DB recovers.
                             Acknowledging here instead would silently lose the
                             order.
                """
                logger.info(f"Received raw message delivery #{method.delivery_tag}: {body.decode('utf-8', errors='replace')}")
                try:
                    payload = json.loads(body.decode("utf-8"))
                except Exception as json_err:
                    logger.error(f"Malformed non-JSON payload received: {json_err}. Acknowledging to avoid queue head-of-line blocking.")
                    ch.basic_ack(delivery_tag=method.delivery_tag)
                    return

                # Robust type coercion according to contract
                try:
                    user_id, number_of_items, total_amount = coerce_order_payload(payload)
                except InvalidOrderError as parse_err:
                    logger.error(f"Invalid order fields in payload {payload}: {parse_err}. Acknowledging and discarding poison message.")
                    ch.basic_ack(delivery_tag=method.delivery_tag)
                    return

                # Persist order to billing database with bounded retries
                db_success = False
                last_db_error = None
                for retry in range(5):
                    if stop_event.is_set():
                        logger.info("Shutdown requested mid-retry; nacking message for redelivery")
                        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
                        return
                    session = db_session_factory()
                    try:
                        order = Order(
                            user_id=user_id,
                            number_of_items=number_of_items,
                            total_amount=total_amount
                        )
                        session.add(order)
                        session.flush()  # INSERT; populates the autoincrement id
                        # Capture ORM state while the session is still open:
                        # after commit/close the instance is detached and
                        # attribute access may fail (or fire a refresh against
                        # a closed session). The log below uses only this
                        # plain value plus the already-coerced locals.
                        order_id = order.id
                        session.commit()
                        logger.info(f"Successfully processed and recorded order #{order_id} for user '{user_id}' (items={number_of_items}, total=${total_amount:.2f})")
                        db_success = True
                        break
                    except Exception as db_err:
                        session.rollback()
                        last_db_error = db_err
                        logger.warning(f"Database insertion retry {retry + 1}/5 failed: {db_err}")
                        time.sleep(1)
                    finally:
                        session.close()

                if db_success:
                    # Acknowledge only after the transaction is committed, so a crash
                    # before this point causes RabbitMQ to redeliver the order.
                    ch.basic_ack(delivery_tag=method.delivery_tag)
                else:
                    # Never ack a failed insert: that would silently discard a
                    # customer order. Requeue so another worker (or a later
                    # delivery of this same message) can process it.
                    logger.error(
                        f"Failed to persist order for user '{user_id}' after 5 attempts "
                        f"({last_db_error}). Nacking back to '{queue_name}' for redelivery "
                        f"once the database is reachable - the order is NOT lost."
                    )
                    # Throttle before requeueing: with prefetch_count=1 an immediate
                    # redelivery would otherwise spin in a tight loop against a
                    # database that is still down.
                    time.sleep(REDELIVERY_BACKOFF_SECONDS)
                    ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

            def callback(ch, method, properties, body):
                # Safety net: ANY escaping exception must nack+requeue, never
                # ack. An unconditional ack here would silently destroy the order.
                try:
                    _handle_message(ch, method, body)
                except Exception as handler_err:
                    logger.exception(f"Unhandled error while processing delivery #{method.delivery_tag}: {handler_err}")
                    ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

            channel.basic_consume(queue=queue_name, on_message_callback=callback, auto_ack=False)

            # Publish the channel to the watchdog BEFORE the blocking call, so
            # a shutdown arriving at any instant either reaches the watchdog (and
            # schedules stop_consuming) or is caught by the check below.
            watchdog.set_active(connection, channel)
            if stop_event.is_set():
                logger.info("Shutdown requested before start_consuming(); leaving the loop.")
                break

            # basic_consume() above returns only after the broker's ConsumeOk,
            # so the consumer is registered from here on. The event is cleared
            # the moment start_consuming() returns or raises, before the retry
            # sleep below, so /ready turns 503 without that 3 s delay.
            if connected_event is not None:
                connected_event.set()
            try:
                channel.start_consuming()
            finally:
                if connected_event is not None:
                    connected_event.clear()

        except (pika.exceptions.AMQPConnectionError, pika.exceptions.AMQPChannelError) as amqp_err:
            if stop_event.is_set():
                break
            logger.warning(f"RabbitMQ connection lost/unavailable: {amqp_err}. Retrying in 3 seconds...")
            time.sleep(3)
        except Exception as e:
            if stop_event.is_set():
                break
            logger.error(f"Unexpected error in consumer loop: {e}. Retrying in 3 seconds...")
            time.sleep(3)
        finally:
            watchdog.clear_active()
            if connection and connection.is_open:
                try:
                    connection.close()
                except Exception:
                    pass

    logger.info("Billing queue consumer stopped cleanly.")