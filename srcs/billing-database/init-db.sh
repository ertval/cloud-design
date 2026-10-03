#!/bin/bash
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
: "${DB_USER:?DB_USER environment variable must be set}"
: "${DB_PASSWORD:?DB_PASSWORD environment variable must be set}"
: "${DB_NAME:?DB_NAME environment variable must be set}"

mkdir -p "$PGDATA" /run/postgresql
chown -R postgres:postgres /run/postgresql

# Reconcile the application role, database and schema against the current
# environment. Runs on EVERY boot, not only on first initialisation, so editing
# a credential in `.env` is picked up instead of leaving a role whose password
# no longer matches (which would surface as a confusing crash-loop in the app
# container while the database container still reports itself healthy).
#
# Exactly ONE temporary instance is started here and stopped again below --
# psql cannot run before this, and starting a second one causes a
# "postmaster.pid already exists" collision and CrashLoopBackOff.
# `-c listen_addresses=''` keeps this half-initialised server off the network.
SOCKET_DIRS=/run/postgresql,/tmp
reconcile() {
  echo "[init-db] Starting temporary instance to reconcile role, database and schema..."
  su-exec postgres pg_ctl -D "$PGDATA" \
    -o "-c listen_addresses='' -c unix_socket_directories=${SOCKET_DIRS}" -w start

  # The password is delivered through a 0600 file read by `psql -f` instead of
  # `-v db_password=...`, which would expose it in /proc/<pid>/cmdline to every
  # process in the container for the lifetime of the command. The file holds a
  # `\set` line, so it must be quoted for psql: single quotes are doubled and
  # backslashes are doubled.
  #
  # psql must run as postgres: the official image's client refuses to run as
  # root ("psql: cannot be run as root"), and only the postgres user can read
  # the scram password file.
  local sql_file escaped_password
  sql_file="$(mktemp)"
  escaped_password="${DB_PASSWORD//\\/\\\\}"
  escaped_password="${escaped_password//\'/\'\'}"
  {
    printf "\\set db_password '%s'\n" "$escaped_password"
    echo "SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password')"
    echo " WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \\gexec"
    echo "SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password')"
    echo " WHERE     EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \\gexec"
    echo "SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')"
    echo " WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name') \\gexec"
    echo "SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db_name', :'db_user') \\gexec"
  } > "$sql_file"
  chown postgres:postgres "$sql_file"
  chmod 600 "$sql_file"

  # db_user / db_name are not secrets and stay in argv; db_password is not.
  su-exec postgres psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 \
       -h /run/postgresql \
       -v db_user="$DB_USER" -v db_name="$DB_NAME" -f "$sql_file" < /dev/null
  rm -f "$sql_file"

  # Pre-create the application table schema in the target database, so the app
  # never has to win a race against `create_all()` and so the schema exists
  # even before the first app container connects. The schema itself lives in
  # init.sql (baked into the image at /usr/local/share/init.sql), where
  # total_amount is NUMERIC(12,2) to match app/orders.py, and is written to be
  # idempotent so this is safe on every restart.
  su-exec postgres psql -U postgres -d "$DB_NAME" -q -v ON_ERROR_STOP=1 \
       -h /run/postgresql -v db_user="$DB_USER" \
       -f /usr/local/share/init.sql < /dev/null

  su-exec postgres pg_ctl -D "$PGDATA" -m fast -w stop
  echo "[init-db] Role, database and schema are in sync with the configured credentials."
}

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[init-db] Initializing new PostgreSQL database cluster in $PGDATA..."
  chown -R postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"

  su-exec postgres initdb -D "$PGDATA" -U postgres \
    --auth-host=scram-sha-256 --auth-local=trust

  # Enable listening on all interfaces and allow network authentication
  echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
  echo "unix_socket_directories = '${SOCKET_DIRS/,/, }'" >> "$PGDATA/postgresql.conf"
  echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
  echo "host all all ::/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"

  reconcile
  echo "[init-db] Database initialization completed successfully."
else
  echo "[init-db] Existing PostgreSQL database cluster detected in $PGDATA."
  if ! reconcile; then
    # Non-fatal: a failure here must not stop the server from starting and
    # serving whatever state the cluster is already in.
    echo "[init-db] WARNING: credential reconciliation failed; continuing with existing cluster state." >&2
  fi
fi

echo "[init-db] Starting PostgreSQL server..."
exec su-exec postgres postgres -D "$PGDATA" -h "*"
