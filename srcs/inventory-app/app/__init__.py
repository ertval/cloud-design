import os
import time
import logging
from flask import Flask
from sqlalchemy import text
from app.extensions import db
from app.movies import movies_bp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [inventory-app] %(message)s"
)
logger = logging.getLogger(__name__)

def create_app():
    app = Flask(__name__)

    db_user = os.getenv("INVENTORY_DB_USER", "inventory_user")
    db_password = os.getenv("INVENTORY_DB_PASSWORD", "inventory_password")
    db_host = os.getenv("INVENTORY_DB_HOST", "inventory-database")
    db_port = os.getenv("INVENTORY_DB_PORT", "5432")
    db_name = os.getenv("INVENTORY_DB_NAME", "inventory_db")

    app.config["SQLALCHEMY_DATABASE_URI"] = (
        f"postgresql+psycopg2://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    )
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    db.init_app(app)
    app.register_blueprint(movies_bp)

    # Healthcheck endpoint for internal probes
    @app.route("/health", methods=["GET"])
    def health():
        return {"status": "healthy"}, 200

    # Wait for database readiness and initialize schema
    with app.app_context():
        max_retries = 30
        for attempt in range(1, max_retries + 1):
            try:
                db.session.execute(text("SELECT 1"))
                db.create_all()
                logger.info("Successfully connected to inventory database and initialized schema.")
                break
            except Exception as e:
                logger.warning(f"Database connection attempt {attempt}/{max_retries} failed: {e}")
                if attempt == max_retries:
                    logger.error("Could not connect to inventory database after max retries.")
                    raise
                time.sleep(2)

    return app

