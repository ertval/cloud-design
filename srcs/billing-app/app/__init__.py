import os
import time
import logging
from flask import Flask, jsonify
from sqlalchemy import text
from app.orders import Order, get_db_engine, init_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [billing-app] %(message)s"
)
logger = logging.getLogger(__name__)

def create_app():
    app = Flask(__name__)

    db_user = os.getenv("BILLING_DB_USER", "billing_user")
    db_password = os.getenv("BILLING_DB_PASSWORD", "billing_password")
    db_host = os.getenv("BILLING_DB_HOST", "billing-database")
    db_port = os.getenv("BILLING_DB_PORT", "5432")
    db_name = os.getenv("BILLING_DB_NAME", "billing_db")

    db_url = f"postgresql+psycopg2://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    engine = get_db_engine(db_url)

    # Retry loop to connect and initialize database schema
    session_factory = None
    max_retries = 30
    for attempt in range(1, max_retries + 1):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            session_factory = init_db(engine)
            logger.info("Successfully connected to billing database and initialized schema.")
            break
        except Exception as e:
            logger.warning(f"Billing database connection attempt {attempt}/{max_retries} failed: {e}")
            if attempt == max_retries:
                logger.error("Could not connect to billing database after max retries.")
                raise
            time.sleep(2)

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"status": "healthy"}), 200

    @app.route("/orders", methods=["GET"])
    @app.route("/api/billing/orders", methods=["GET"])
    def list_orders():
        session = session_factory()
        try:
            orders = session.query(Order).order_by(Order.id.asc()).all()
            return jsonify({"orders": [o.to_dict() for o in orders]}), 200
        finally:
            session.close()

    app.session_factory = session_factory
    return app, session_factory

