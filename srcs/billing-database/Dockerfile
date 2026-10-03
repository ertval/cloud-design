# syntax=docker/dockerfile:1
# =============================================================================
# billing-database - PostgreSQL 17 on the OFFICIAL image.
#
# The previous `FROM postgres:16-alpine` + hand-rolled `apk add postgresql17`
# combination was broken: postgres:16-alpine has no postgresql17 package, no
# /usr/libexec/postgresql17 and no su-exec, so init-db.sh could not run at all.
# Building ON the official postgres:17-alpine image means the binaries, the
# `postgres` user, PGDATA and the socket directory already exist and are the
# exact paths the upstream entrypoint expects.
# =============================================================================
FROM postgres:17-alpine

# su-exec: this script runs as root (it has to chown PGDATA) and must drop to
# the `postgres` user for initdb/postgres/pg_ctl/psql.
# bash: init-db.sh is `#!/bin/bash`; the image ships only busybox ash.
# coreutils-shadow-free: busybox already provides mktemp, awk and cp.
RUN apk add --no-cache su-exec bash && \
    mkdir -p /var/lib/postgresql/data /run/postgresql && \
    chown -R postgres:postgres /var/lib/postgresql /run/postgresql

ENV PGDATA=/var/lib/postgresql/data

# The official image already sets this, but state it explicitly because the
# whole shutdown story below depends on it being POSTGRES_FAST.
ENV PGSTOP=fast

# COPY --chmod sets the executable bit inside this layer instead of adding a
# separate `RUN chmod +x` layer.
COPY --chmod=0755 init-db.sh /usr/local/bin/init-db.sh
# The schema is a real image artefact, not an inline heredoc: init-db.sh
# applies it on every start and it is the file the audit suite checks.
COPY --chmod=0644 init.sql /usr/local/share/init.sql

EXPOSE 5432

# PostgreSQL maps SIGTERM to a *smart* shutdown, which waits for every client to
# disconnect. The application containers hold pooled connections, so a plain
# `docker stop` would hang until the grace period expires and the daemon
# SIGKILLs the server (exit 137), which is an unclean crash of the data files.
# SIGINT is PostgreSQL's *fast* shutdown: it rolls back open transactions and
# disconnects clients immediately. This is the same signal the official image
# ships with; it is repeated here so the behaviour is visible in this repo.
STOPSIGNAL SIGINT

# Probes the ROLE and DATABASE this instance actually serves. During the
# initialisation phase (initdb + role/database/schema reconciliation) the server
# is deliberately started with listen_addresses='' so this check fails and the
# container is reported "starting" rather than healthy-but-useless.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=12 \
    CMD pg_isready -h 127.0.0.1 -U "${DB_USER:-postgres}" -d "${DB_NAME:-postgres}" -q || exit 1

ENTRYPOINT ["/usr/local/bin/init-db.sh"]
