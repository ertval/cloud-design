import os
import sys
import signal
import threading
import logging
from waitress import create_server
from app import create_app

logger = logging.getLogger(__name__)


def _install_shutdown_handler(shutdown_event: threading.Event) -> None:
    """Make `docker stop` (SIGTERM) exit cleanly instead of being SIGKILLed.

    Waitress blocks its own thread in an event loop, so without an explicit
    handler the process waits out Docker's whole grace period and is then killed
    (exit 137). Handling SIGTERM/SIGINT here lets the HTTP server close its
    listening socket.

    It is installed as the FIRST thing `__main__` does, before create_app():
    that call blocks for up to DB_CONNECT_MAX_RETRIES x DB_CONNECT_RETRY_DELAY
    seconds waiting for a cold database, and a SIGTERM inside that window used to
    be lost - the container then sat out the whole grace period and was SIGKILLed.
    Both the database wait and the server loop poll the same event.
    """
    def _handler(signum, _frame):
        logger.info(f"Received signal {signum}; shutting down gracefully")
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _handler)


if __name__ == "__main__":
    port = int(os.getenv("APP_PORT") or "8080")

    # First, before anything that can block: a shutdown requested from here on
    # is honoured by the database wait inside create_app().
    shutdown_event = threading.Event()
    _install_shutdown_handler(shutdown_event)

    app = create_app(stop_event=shutdown_event)
    if app is None:
        # create_app() abandoned the database wait because a signal arrived.
        # Exiting 0 (not 137, and not a traceback) is what makes
        # `docker compose stop` during a cold start look clean.
        logger.info("inventory-app stopped during startup because a shutdown was requested.")
        sys.exit(0)

    if shutdown_event.is_set():
        # A signal landed between the database becoming reachable and this
        # check: never start serving traffic into a shutdown.
        logger.info("inventory-app stopped before serving because a shutdown was requested.")
        sys.exit(0)

    logger.info(f"Starting inventory-app on 0.0.0.0:{port}...")
    server = create_server(app, host="0.0.0.0", port=port, clear_untrusted_proxy_headers=True)
    server_thread = threading.Thread(target=server.run, daemon=True, name="WaitressServer")
    server_thread.start()
    logger.info(f"HTTP server listening on 0.0.0.0:{port}")

    shutdown_event.wait()

    logger.info("Closing HTTP server...")
    try:
        server.close()
    except Exception as close_err:  # pragma: no cover - best effort
        logger.warning(f"Error closing HTTP server: {close_err}")
    server_thread.join(timeout=5)
    logger.info("inventory-app stopped cleanly.")
