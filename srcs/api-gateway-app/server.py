import os
import logging
from waitress import serve
from app import create_app

logger = logging.getLogger(__name__)

if __name__ == "__main__":
    port = int(os.getenv("APP_PORT", "3000"))
    app = create_app()
    logger.info(f"Starting api-gateway-app on 0.0.0.0:{port}...")
    serve(app, host="0.0.0.0", port=port)

