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
    -- VARCHAR(255) is the API contract, not an arbitrary choice: the same 255 is
    -- MAX_TITLE_LENGTH in srcs/inventory-app/app/validation.py and String(255)
    -- in srcs/inventory-app/app/movies.py. Change all three together.
    title       VARCHAR(255) NOT NULL,
    -- TEXT is deliberately UNBOUNDED: a description can never trigger
    -- StringDataRightTruncation, so it needs no length validation. The 1 MiB
    -- MAX_CONTENT_LENGTH on the request body is the real ceiling.
    description TEXT DEFAULT ''
);

-- The application rejects an empty or over-long title with a 400 before it
-- reaches this table, but `VARCHAR(255)` only guards the upper bound and
-- `NOT NULL` still admits ''. This constraint makes the stored contract
-- self-enforcing, so a writer that bypasses the validator (a migration, psql, a
-- future endpoint) is rejected by PostgreSQL instead of producing a row the
-- API would have refused.
--
-- Guarded by the catalog check because init.sql runs on EVERY container start:
-- a bare ADD CONSTRAINT would abort the second boot with "already exists".
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.movies'::regclass
          AND conname = 'movies_title_length_ck'
    ) THEN
        ALTER TABLE movies
            ADD CONSTRAINT movies_title_length_ck
            CHECK (char_length(title) BETWEEN 1 AND 255);
    END IF;
END
$$;

SELECT format('ALTER TABLE movies OWNER TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO %I', :'db_user') \gexec
