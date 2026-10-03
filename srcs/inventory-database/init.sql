-- Canonical schema for the inventory movie catalogue.
--
-- This file is the single source of truth for the table definition. It is
-- applied by /usr/local/bin/init-db.sh on every container start (idempotent,
-- IF NOT EXISTS), which means:
--   * the schema exists before the first application container connects, so
--     `db.create_all()` in app/__init__.py never races the database image, and
--   * adding a column here reaches every environment on the next restart
--     instead of only on a fresh volume.
--
-- It must stay in sync with the SQLAlchemy model in srcs/inventory-app/app/movies.py.

-- The application role is created and reconciled by init-db.sh from DB_USER.
-- Its password is NEVER written here: it is delivered through a 0600 file that
-- is removed immediately after psql reads it, so it never reaches argv,
-- /proc/<pid>/cmdline or this repository.

-- Ownership of the public schema itself. Without this, tables created by
-- init-db.sh would be owned by `postgres` and the application role could not
-- create or alter anything on a fresh volume.
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'db_user') \gexec

CREATE TABLE IF NOT EXISTS movies (
    id          SERIAL PRIMARY KEY,
    title       VARCHAR(255) NOT NULL,
    description TEXT DEFAULT ''
);

SELECT format('ALTER TABLE movies OWNER TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO %I', :'db_user') \gexec
