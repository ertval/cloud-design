# syntax=docker/dockerfile:1
# =============================================================================
# inventory-app - movie catalogue microservice (Flask + SQLAlchemy + psycopg2).
#
# Build context is this directory only (see .dockerignore and the `context:`
# key in docker-compose.yml).
# =============================================================================
# -----------------------------------------------------------------------------
# Stage 1 - dependency builder.

# -----------------------------------------------------------------------------
FROM python:3.11-alpine AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

# No compiler is installed here on purpose: every pinned dependency ships a
# musllinux wheel (psycopg2-binary included), and --only-binary=:all: below
# guarantees pip can never silently fall back to a source build that would
# drag gcc/musl-dev into the build.
WORKDIR /build

COPY requirements.txt ./

# --only-binary=:all: fails loudly instead of quietly compiling from
# source. A new pin without a musllinux wheel should break the build,
# not add 30 MB of toolchain and a minute of build time.
RUN pip install --no-cache-dir --only-binary=:all: --prefix=/install -r requirements.txt

# -----------------------------------------------------------------------------
# Stage 2 - minimal hardened runtime.
# -----------------------------------------------------------------------------
FROM python:3.11-alpine AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_PORT=8080

RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -h /home/appuser -s /sbin/nologin appuser

WORKDIR /usr/src/app

COPY --from=builder /install /usr/local

COPY --chown=appuser:appgroup --chmod=0644 server.py ./
COPY --chown=appuser:appgroup app/ ./app/

USER appuser

# Build-time smoke test as the unprivileged user. NOTE: the Alpine
# `py3-psycopg2` package is intentionally NOT installed: it would put a second
# provider in the same site-packages/psycopg2 directory that pip's binary wheel
# owns and corrupt apk's package database.
RUN python3 -c "import flask, waitress, flask_sqlalchemy, sqlalchemy, psycopg2" && \
    python3 -c "import pathlib;[compile(p.read_text(),str(p),'exec') for p in pathlib.Path('.').rglob('*.py')]" && \
    echo "sources compile"

EXPOSE 8080

# /ready is used rather than /health because this service owns database state:
# it must only be reported healthy once SELECT 1 succeeds, so the load balancer
# stops sending it traffic during a database blip instead of restarting it.
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=6 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/ready', timeout=4)" || exit 1

CMD ["python3", "server.py"]
