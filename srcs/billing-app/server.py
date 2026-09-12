import os
import threading
import logging
from waitress import serve
from app import create_app
from app.consume_queue import start_consuming

logger = logging.getLogger(__name__)

if __name__ == "__main__":
    port = int(os.getenv("APP_PORT", "8080"))
    app, session_factory = create_app()

    # Launch consumer thread for asynchronous order ingestion
    consumer_thread = threading.Thread(
        target=start_consuming,
        args=(session_factory,),
        daemon=True,
        name="BillingQueueConsumer"
    )
    consumer_thread.start()
    logger.info(f"Billing consumer background thread started. Launching HTTP server on 0.0.0.0:{port}...")

    serve(app, host="0.0.0.0", port=port)

