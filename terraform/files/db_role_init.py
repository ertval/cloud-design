"""ECS init container: create or update one app's least-privilege PostgreSQL role.

Runs before the app container in the same ECS task (terraform/ecs_services.tf,
dependsOn condition SUCCESS), from the app's own image, which already ships
psycopg2. It connects as the RDS master user, so the master credentials reach
only this container, which exits within seconds; the long-running app container
gets the app role's credentials.

The role it leaves behind can log in, connect to the app database, and create
and use tables in its public schema, and nothing else: no SUPERUSER, CREATEDB,
CREATEROLE, REPLICATION or BYPASSRLS and no membership in any other role.
CONNECT on the app database is revoked from PUBLIC and granted to the role (the
default postgres database keeps PostgreSQL's PUBLIC CONNECT, as for any role).
Tables the master user created before this role existed (a stack deployed
before the change) are handed over to it, so the app keeps working on them.

Safe to run on every task start: the whole run is one transaction behind an
advisory lock, so two tasks starting together run one after the other, and a
repeat run only applies the same state again. The password goes to the server
as a SCRAM verifier computed here, never as plaintext, so it cannot appear in a
server log. Exits 0 on success and 1 on any failure, so ECS never starts the
app container on a missing or wrong role.

Environment (set by the task definition):
  DB_HOST, DB_PORT, DB_NAME            the RDS instance and the app's database
  MASTER_DB_USER, MASTER_DB_PASSWORD   from the instance's master secret
  APP_DB_USER, APP_DB_PASSWORD         from the app role's secret
"""

import os
import sys
import time

import psycopg2
import psycopg2.extensions
from psycopg2 import sql

LOCK_KEY = "cloud-design-db-role-init"
CONNECT_ATTEMPTS = 10


class RoleInitError(Exception):
    pass


def log(message):
    print(f"db-role-init: {message}", flush=True)


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RoleInitError(f"{name} is not set")
    return value


def connect():
    params = {
        "host": env("DB_HOST"),
        "port": int(env("DB_PORT")),
        "dbname": env("DB_NAME"),
        "user": env("MASTER_DB_USER"),
        "password": env("MASTER_DB_PASSWORD"),
        # Always require: these are the master credentials. RDS refuses
        # plaintext anyway (rds.force_ssl = 1).
        "sslmode": "require",
        "connect_timeout": 10,
        "application_name": "db-role-init",
        # Fail instead of hanging if a table handover waits on a busy table;
        # ECS then starts the task again.
        "options": "-c lock_timeout=30s -c statement_timeout=60s",
    }
    for attempt in range(1, CONNECT_ATTEMPTS + 1):
        try:
            return psycopg2.connect(**params)
        except psycopg2.OperationalError as err:
            log(f"connection attempt {attempt}/{CONNECT_ATTEMPTS} failed: {str(err).strip()}")
            if attempt == CONNECT_ATTEMPTS:
                raise
            time.sleep(3)


def ensure_role(conn, cur, app_user, app_password, db_name):
    role = sql.Identifier(app_user)

    cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (LOCK_KEY,))

    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (app_user,))
    created = cur.fetchone() is None
    if created:
        # CREATE ROLE defaults to NOSUPERUSER NOCREATEDB NOCREATEROLE
        # NOREPLICATION NOBYPASSRLS. They are checked below rather than set
        # here, because the RDS master is not a superuser and may not name
        # some of them.
        cur.execute(sql.SQL("CREATE ROLE {} WITH LOGIN").format(role))

    verifier = psycopg2.extensions.encrypt_password(app_password, app_user, conn, "scram-sha-256")
    cur.execute(sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(role, sql.Literal(verifier)))

    # A role with this name that already existed must not be handed to the app
    # if it is more than an app role.
    cur.execute(
        "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls"
        " FROM pg_roles WHERE rolname = %s",
        (app_user,),
    )
    if cur.fetchone()[0]:
        raise RoleInitError(f"role {app_user} has privileged attributes; refusing to use it")
    cur.execute(
        "SELECT string_agg(g.rolname, ', ') FROM pg_auth_members m"
        " JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles r ON r.oid = m.member"
        " WHERE r.rolname = %s",
        (app_user,),
    )
    memberships = cur.fetchone()[0]
    if memberships:
        raise RoleInitError(f"role {app_user} is a member of {memberships}; refusing to use it")

    database = sql.Identifier(db_name)
    cur.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(database))
    cur.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(database, role))
    cur.execute(sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(role))

    # Tables the master user created while the app still connected as master.
    # PostgreSQL 16 only lets a non-superuser give a table to a role it can
    # SET ROLE to, so the master first takes membership of the app role (it
    # created the role, so it holds ADMIN on it). INHERIT FALSE: the master
    # does not pick up the app's privileges through it. Ownership of a table
    # also moves the sequences of its serial columns.
    cur.execute(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tableowner = current_user"
        " ORDER BY tablename"
    )
    tables = [row[0] for row in cur.fetchall()]
    if tables:
        cur.execute(sql.SQL("GRANT {} TO CURRENT_USER WITH INHERIT FALSE, SET TRUE").format(role))
        for table in tables:
            cur.execute(sql.SQL("ALTER TABLE {} OWNER TO {}").format(sql.Identifier("public", table), role))

    return created, tables


def main():
    try:
        app_user = env("APP_DB_USER")
        app_password = env("APP_DB_PASSWORD")
        db_name = env("DB_NAME")
        conn = connect()
        try:
            with conn, conn.cursor() as cur:  # one transaction, committed on success
                created, tables = ensure_role(conn, cur, app_user, app_password, db_name)
        finally:
            conn.close()
    except (RoleInitError, psycopg2.Error, ValueError) as err:
        log(f"FAILED: {str(err).strip()}")
        return 1
    handed = f"; tables handed over: {', '.join(tables)}" if tables else ""
    log(f"role {app_user} {'created' if created else 'up to date'} on database {db_name}{handed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
