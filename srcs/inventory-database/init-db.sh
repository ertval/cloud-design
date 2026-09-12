#!/bin/bash
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
: "${DB_USER:?DB_USER environment variable must be set}"
: "${DB_PASSWORD:?DB_PASSWORD environment variable must be set}"
: "${DB_NAME:?DB_NAME environment variable must be set}"

mkdir -p "$PGDATA" /run/postgresql
chown -R postgres:postgres /run/postgresql

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[init-db] Initializing new PostgreSQL database cluster in $PGDATA..."
  chown -R postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  
  su-exec postgres initdb -D "$PGDATA" -U postgres \
    --auth-host=scram-sha-256 --auth-local=trust

  # Enable listening on all interfaces and allow network authentication
  echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
  echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
  echo "host all all ::/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"

  # Start temporary instance to create database and user
  su-exec postgres pg_ctl -D "$PGDATA" -w start

  echo "[init-db] Creating application role and database..."
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
       -v db_user="$DB_USER" -v db_password="$DB_PASSWORD" -v db_name="$DB_NAME" \
     <<'PSQL'
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password')
 WHERE     EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name') \gexec
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db_name', :'db_user') \gexec
PSQL

  su-exec postgres pg_ctl -D "$PGDATA" -m fast -w stop
  echo "[init-db] Database initialization completed successfully."
else
  echo "[init-db] Existing PostgreSQL database cluster detected in $PGDATA."
fi

echo "[init-db] Starting PostgreSQL server..."
exec su-exec postgres postgres -D "$PGDATA" -h "*"

