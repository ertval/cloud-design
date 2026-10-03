import os
import time
import logging
from flask import Flask, jsonify
from sqlalchemy import text
from sqlalchemy.engine import URL
from app.orders import Order, get_db_engine, init_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [billing-app] %(message)s"
)
logger = logging.getLogger(__name__)

# Shown to any client while the database is unreachable. Fixed text on purpose:
# `str(OperationalError)` names the internal host ("could not translate host name
# \"billing-database\"") and the database name. The exception goes to the log,
# which is where an operator needs it.
DATABASE_UNAVAILABLE_MESSAGE = "The billing database is currently unavailable"


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


def create_app(stop_event=None):
    app = Flask(__name__)

    # Secrets MUST come from env; host/port/db-name keep safe non-secret defaults.
    db_user = _require_env("BILLING_DB_USER")
    db_password = _require_env("BILLING_DB_PASSWORD")
    db_host = _env_or_default("BILLING_DB_HOST", "billing-database")
    try:
        db_port = int(_env_or_default("BILLING_DB_PORT", "5432"))
    except ValueError:
        logger.warning("Invalid BILLING_DB_PORT; falling back to 5432.")
        db_port = 5432
    db_name = _env_or_default("BILLING_DB_NAME", "billing_db")

    # URL.create() percent-encodes the password; f-string interpolation would
    # break on any password containing @ : / ? # or %.
    db_url = URL.create(
        "postgresql+psycopg2",
        username=db_user,
        password=db_password,
        host=db_host,
        port=db_port,
        database=db_name,
    )
    engine = get_db_engine(db_url)

    # Retry loop to connect and initialize database schema.
    # The budget must comfortably exceed a COLD database start: on a fresh
    # cluster PostgreSQL needed ~145s to accept connections (initdb + role,
    # database and table creation), while a 30 x 2s = 60s budget made the app
    # exit and be restarted twice before the database was up.
    #
    # `stop_event` (the SIGTERM event installed by server.py BEFORE this call)
    # is honoured between attempts: without that check a `docker stop` arriving
    # during a cold start would have to wait out the entire budget - up to
    # 180 x 2s = 360s - and be SIGKILLed (exit 137). Returns (None, None) so the
    # caller can exit 0 instead.
    #
    # A malformed budget must not crash start-up either: a typo in the env var
    # falls back to the documented default with a warning rather than raising
    # ValueError out of the initialiser.
    try:
        max_retries = int(_env_or_default("DB_CONNECT_MAX_RETRIES", "180"))
    except ValueError:
        logger.warning("Invalid DB_CONNECT_MAX_RETRIES; falling back to 180.")
        max_retries = 180
    try:
        retry_delay = float(_env_or_default("DB_CONNECT_RETRY_DELAY", "2"))
    except ValueError:
        logger.warning("Invalid DB_CONNECT_RETRY_DELAY; falling back to 2.")
        retry_delay = 2.0
    session_factory = None
    for attempt in range(1, max_retries + 1):
        if stop_event is not None and stop_event.is_set():
            logger.info("Shutdown requested while waiting for the billing database; abandoning startup.")
            return None, None
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
            time.sleep(retry_delay)

    # Liveness and readiness answer DIFFERENT questions and must not be the
    # same endpoint:
    #   /health  -> "is this process still alive?"  It must NOT depend on any
    #               external system. If it did, a transient database outage
    #               would make Docker/kubelet kill the container (exit 137) and
    #               the app's own reconnect loop would never get a chance to run.
    #   /ready   -> "should this container receive traffic?"  This one checks
    #               the database, so a container that cannot reach it is pulled
    #               out of the load balancer's target group instead of being
    #               restarted.
    @app.route("/health", methods=["GET"])
    def health():
        # Liveness is unauthenticated and therefore public: DB-independent and
        # carrying nothing beyond this literal - no version, host, configuration
        # or row counts.
        return jsonify({"status": "healthy"}), 200

    @app.route("/ready", methods=["GET"])
    def ready():
        try:
            session = session_factory()
            try:
                session.execute(text("SELECT 1"))
            finally:
                session.close()
            return jsonify({"status": "ready", "database": "reachable"}), 200
        except Exception as ready_err:
            # The driver message names the internal host, so it is logged and not
            # returned. A client only learns that this instance is not ready.
            logger.error(f"Readiness probe failed: {ready_err!r}")
            return jsonify({
                "status": "not-ready",
                "database": "unreachable",
                "error": DATABASE_UNAVAILABLE_MESSAGE,
            }), 503

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
