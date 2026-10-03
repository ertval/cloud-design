import os
import time
import logging
from flask import Flask, jsonify
from sqlalchemy import text
from sqlalchemy.engine import URL
from sqlalchemy.exc import InterfaceError, OperationalError
from app.extensions import db
from app.movies import movies_bp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [inventory-app] %(message)s"
)
logger = logging.getLogger(__name__)

# Shown to any client while the database is unreachable. Fixed text on purpose:
# `str(OperationalError)` contains the internal host ("could not translate host
# name \"inventory-database\"") and the database name, which is internal
# topology a client has no use for. The exception itself is logged in full.
DATABASE_UNAVAILABLE_MESSAGE = "The inventory database is currently unavailable"


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
    try:
        db_port = int(_env_or_default("INVENTORY_DB_PORT", "5432"))
    except ValueError:
        logger.warning("Invalid INVENTORY_DB_PORT; falling back to 5432.")
        db_port = 5432
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

    # A database outage is a DEPENDENCY failure, so it must be reported as 503
    # rather than escaping as an unhandled exception (which waitress turns into a
    # generic 500 page). A 500 tells an operator this service is broken, burns
    # the 5XX error budget and trips 5XX alarms for what is a transient,
    # self-healing outage of PostgreSQL. Registered for the two exception classes
    # SQLAlchemy raises when it cannot talk to the server; IntegrityError /
    # DataError / ProgrammingError deliberately stay 500s because those ARE bugs.
    #
    # Only these two SPECIFIC classes are registered on purpose. A catch-all
    # `@app.errorhandler(Exception)` looks tempting - it would turn every
    # unexpected error into a tidy JSON 500 - but Flask resolves a handler by
    # walking the exception's MRO, so it also swallows HTTPException: `/nope`
    # and `PATCH /api/movies/1` were observed returning 500 instead of 404 and
    # 405. Anything genuinely unexpected still surfaces as waitress's 500 page,
    # which leaks nothing either.
    @app.errorhandler(InterfaceError)
    @app.errorhandler(OperationalError)
    def _database_unavailable(err):
        logger.error(f"Database operation failed: {err!r}")
        try:
            db.session.rollback()
        except Exception:  # pragma: no cover - the session is already poisoned
            logger.debug("Rollback after database failure raised", exc_info=True)
        return jsonify({"error": DATABASE_UNAVAILABLE_MESSAGE}), 503

    # Liveness and readiness are deliberately different endpoints. /health must
    # not depend on the database, otherwise a transient database outage makes
    # the orchestrator kill the container (exit 137) before the app's own
    # reconnect loop can recover. /ready does check the database, so an unready
    # container is pulled out of the load balancer's target group instead of
    # being restarted.
    @app.route("/health", methods=["GET"])
    def health():
        # Liveness is unauthenticated and therefore public: it must stay
        # DB-independent and carry nothing beyond this literal - no version, no
        # host, no configuration, no row counts.
        return jsonify({"status": "healthy"}), 200

    @app.route("/ready", methods=["GET"])
    def ready():
        try:
            db.session.execute(text("SELECT 1"))
            return jsonify({"status": "ready", "database": "reachable"}), 200
        except Exception as ready_err:
            # The full driver/psycopg2 message goes to the log; the client gets a
            # stable, host-free body. Roll back so a failed probe does not leave
            # a poisoned session behind for the next request.
            logger.error(f"Readiness probe failed: {ready_err!r}")
            try:
                db.session.rollback()
            except Exception:  # pragma: no cover
                logger.debug("Rollback after failed readiness probe raised", exc_info=True)
            return jsonify({
                "status": "not-ready",
                "database": "unreachable",
                "error": DATABASE_UNAVAILABLE_MESSAGE,
            }), 503

    # Wait for database readiness and initialize schema.
    # The budget must comfortably exceed a COLD database start: on a fresh
    # cluster PostgreSQL needed ~145s to accept connections (initdb + role,
    # database and table creation), while a 30 x 2s = 60s budget made the app
    # exit and be restarted twice before the database was up.
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
