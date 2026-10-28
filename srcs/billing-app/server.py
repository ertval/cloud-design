import os
import signal
import sys
import threading
import logging
from waitress import create_server
from app import create_app
from app.consume_queue import start_consuming

logger = logging.getLogger(__name__)


def _install_shutdown_handler(shutdown_event: threading.Event) -> None:
    """Make `docker stop` (SIGTERM) exit cleanly instead of being SIGKILLed.

    Waitress blocks the main thread in its event loop, so without an explicit
    handler the process waits out Docker's full grace period and is then killed
    (exit 137). Handling SIGTERM/SIGINT here lets the HTTP server close its
    listening socket and the consumer thread finish its current message.

    It is installed as the FIRST thing `__main__` does, before create_app():
    that call blocks for up to DB_CONNECT_MAX_RETRIES x DB_CONNECT_RETRY_DELAY
    seconds waiting for a cold database, and a SIGTERM inside that window used
    to be lost - the container then sat out the whole grace period and was
    SIGKILLed. Both the database wait and the consumer loop poll the same event.
    """
    def _handler(signum, _frame):
        logger.info(f"Received signal {signum}; shutting down gracefully")
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _handler)


if __name__ == "__main__":
    port = int(os.getenv("APP_PORT", "8080") or "8080")

    # First, before anything that can block: a shutdown requested from here on
    # is honoured by the database wait below and by the consumer loop.
    shutdown_event = threading.Event()
    _install_shutdown_handler(shutdown_event)

    # Set by the consumer thread while the broker has it registered on the
    # queue; /ready reports 503 while it is clear.
    consumer_connected = threading.Event()
    app, session_factory = create_app(stop_event=shutdown_event, consumer_connected=consumer_connected)
    if app is None:
        # create_app() abandoned the database wait because a signal arrived.
        # Exiting 0 (not 137, and not a traceback) is what makes
        # `docker compose stop` during a cold start look clean.
        logger.info("billing-app stopped during startup because a shutdown was requested.")
        sys.exit(0)

    if shutdown_event.is_set():
        # A signal landed between the database becoming reachable and this
        # check: never start serving traffic into a shutdown.
        logger.info("billing-app stopped before serving because a shutdown was requested.")
        sys.exit(0)

    # Launch consumer thread for asynchronous order ingestion. A real stop_event
    # is passed so the consumer loop can terminate and close its AMQP channel.
    consumer_stop = threading.Event()
    consumer_thread = threading.Thread(
        target=start_consuming,
        args=(session_factory, consumer_stop, consumer_connected),
        daemon=True,
        name="BillingQueueConsumer"
    )
    consumer_thread.start()
    logger.info(f"Billing consumer background thread started. Launching HTTP server on 0.0.0.0:{port}...")

    server = create_server(app, host="0.0.0.0", port=port, clear_untrusted_proxy_headers=True)
    server_thread = threading.Thread(target=server.run, daemon=True, name="WaitressServer")
    server_thread.start()
    logger.info(f"HTTP server listening on 0.0.0.0:{port}")

    shutdown_event.wait()

    logger.info("Stopping queue consumer and closing HTTP server...")
    consumer_stop.set()
    try:
        server.close()
    except Exception as close_err:  # pragma: no cover - best effort
        logger.warning(f"Error closing HTTP server: {close_err}")

    consumer_thread.join(timeout=5)
    server_thread.join(timeout=5)
    logger.info("billing-app stopped cleanly.")