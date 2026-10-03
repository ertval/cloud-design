import os
import time
import logging
from flask import Flask, jsonify
from sqlalchemy import text
from sqlalchemy.engine import URL
from app.extensions import db
from app.movies import movies_bp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [inventory-app] %(message)s"
)
logger = logging.getLogger(__name__)


def _require_env(name: str) -> str:
    """Return required secret env var or raise (no hardcoded fallback for secrets).

    Credentials are injected exclusively from the environment (compose `.env` /
    k8s secretKeyRef, see manifests/secrets.yaml). There are deliberately NO
    hardcoded fallback values: a silent fallback would authenticate with a
    password that differs from the Secret, turning a wiring bug into a
    confusing authentication error.
    """
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


def create_app():
    app = Flask(__name__)

    # Secrets MUST come from env; host/port/db-name keep safe non-secret defaults.
    db_user = _require_env("INVENTORY_DB_USER")
    db_password = _require_env("INVENTORY_DB_PASSWORD")
    db_host = _env_or_default("INVENTORY_DB_HOST", "inventory-database")
    db_port = _env_or_default("INVENTORY_DB_PORT", "5432")
    db_name = _env_or_default("INVENTORY_DB_NAME", "inventory_db")

    # URL.create() percent-encodes the password; f-string interpolation would
    # break on any password containing @ : / ? # or %.
    app.config["SQLALCHEMY_DATABASE_URI"] = URL.create(
        "postgresql+psycopg2",
        username=db_user,
        password=db_password,
        host=db_host,
        port=db_port,
        database=db_name,
    )
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    db.init_app(app)
    app.register_blueprint(movies_bp)

    # Liveness and readiness are deliberately different endpoints. /health must
    # not depend on the database, otherwise a transient database outage makes
    # the orchestrator kill the container (exit 137) before the app's own
    # reconnect loop can recover. /ready does check the database, so an unready
    # container is pulled out of the load balancer's target group instead of
    # being restarted.
    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"status": "healthy"}), 200

    @app.route("/ready", methods=["GET"])
    def ready():
        try:
            db.session.execute(text("SELECT 1"))
            return jsonify({"status": "ready", "database": "reachable"}), 200
        except Exception as ready_err:
            return jsonify({"status": "not-ready", "error": str(ready_err)}), 503

    # Wait for database readiness and initialize schema.
    # The budget must comfortably exceed a COLD database start: on a fresh
    # cluster PostgreSQL needed ~145s to accept connections (initdb + role,
    # database and table creation), while a 30 x 2s = 60s budget made the app
    # exit and be restarted twice before the database was up.
    max_retries = int(_env_or_default("DB_CONNECT_MAX_RETRIES", "180"))
    retry_delay = float(_env_or_default("DB_CONNECT_RETRY_DELAY", "2"))
    with app.app_context():
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
                time.sleep(retry_delay)

    return app
