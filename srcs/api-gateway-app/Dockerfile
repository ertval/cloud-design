# syntax=docker/dockerfile:1
# =============================================================================
# api-gateway-app - single public entry point of the platform.
#
# Build context is this directory only (see .dockerignore and the `context:`
# key in docker-compose.yml), which keeps the transfer tiny and makes every
# layer cache hit on a source-only change.
# =============================================================================
# -----------------------------------------------------------------------------
# Stage 1 - dependency builder.
# Every wheel used here (Flask, waitress, pika, requests) is pure-Python or
# ships a musllinux wheel, so no compiler is installed in ANY stage.
# -----------------------------------------------------------------------------
FROM python:3.11-alpine AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /build

# requirements.txt is copied on its own so that editing application code does
# not invalidate the dependency layer.
COPY requirements.txt ./

# --prefix funnels every artefact (libs, scripts, data) into ONE directory, so
# the runtime stage copies it with a single `COPY --from` instead of three.
# --only-binary=:all: fails loudly instead of quietly compiling from
# source. A new pin without a musllinux wheel should break the build,
# not add 30 MB of toolchain and a minute of build time.
RUN pip install --no-cache-dir --only-binary=:all: --prefix=/install -r requirements.txt

# -----------------------------------------------------------------------------
# Stage 2 - minimal hardened runtime. No pip, no compiler, no package manager.
# -----------------------------------------------------------------------------
FROM python:3.11-alpine AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_PORT=3000

# Dedicated unprivileged identity: no login shell, no home directory content.
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S -G appgroup -h /home/appuser -s /sbin/nologin appuser

WORKDIR /usr/src/app

COPY --from=builder /install /usr/local

# --chmod sets the mode in the same layer instead of adding a separate
# `RUN chmod` layer for a few kB of metadata.
COPY --chown=appuser:appgroup --chmod=0644 server.py openapi.yaml ./
COPY --chown=appuser:appgroup app/ ./app/

# /usr/src/logs is the mount point for the persistent named volume declared in
# docker-compose.yml. It must be owned by appuser, otherwise Docker seeds the
# fresh volume from this directory with root:root ownership and the gateway's
# RotatingFileHandler fails with PermissionError at runtime.
RUN mkdir -p /usr/src/logs && chown -R appuser:appgroup /usr/src/logs

USER appuser

# Build-time smoke test, executed as the unprivileged user: a broken
# requirements.txt or a syntax error fails the build instead of the first
# container start. `PyYAML` is deliberately absent - openapi.yaml is served as
# a static file with send_from_directory and is never parsed in Python.
# A syntax check WITHOUT writing bytecode: py_compile would try to create
# __pycache__ inside a WORKDIR this user does not own and fail with EACCES.
RUN python3 -c "import flask, waitress, pika, requests" && \
    python3 -c "import pathlib;[compile(p.read_text(),str(p),'exec') for p in pathlib.Path('.').rglob('*.py')]" && \
    echo "sources compile" && ls -l app/__init__.py

EXPOSE 3000

# /health is deliberately DB-independent: it answers "is this process alive?".
# A database or broker outage must never mark the edge router unhealthy and get
# it killed (exit 137) - that is what /ready is for on the stateful services.
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=6 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health', timeout=4)" || exit 1

CMD ["python3", "server.py"]
