import os
import signal
import threading
import logging
from waitress import create_server
from app import create_app
from app.consume_queue import start_consuming

logger = logging.getLogger(__name__)


def _install_shutdown_handler(shutdown_event: threading.Event) -> None:
    """Make `docker stop` (SIGTERM) exit cleanly instead of being SIGKILLed.

    Waitress blocks the main thread in its event loop, so without an explicit
    handler the process waits out Docker's full 10 s grace period and is then
    killed (exit 137). Handling SIGTERM/SIGINT here lets the HTTP server close
    its listening socket and the consumer thread finish its current message.
    """
    def _handler(signum, _frame):
        logger.info(f"Received signal {signum}; shutting down gracefully")
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _handler)


if __name__ == "__main__":
    port = int(os.getenv("APP_PORT", "8080") or "8080")
    app, session_factory = create_app()

    shutdown_event = threading.Event()
    _install_shutdown_handler(shutdown_event)

    # Launch consumer thread for asynchronous order ingestion. A real stop_event
    # is passed so the consumer loop can terminate and close its AMQP channel.
    consumer_stop = threading.Event()
    consumer_thread = threading.Thread(
        target=start_consuming,
        args=(session_factory, consumer_stop),
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