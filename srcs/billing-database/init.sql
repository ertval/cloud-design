-- Canonical schema for billing orders.
--
-- This file is the single source of truth for the table definition. It is
-- applied by /usr/local/bin/init-db.sh on every container start (idempotent,
-- IF NOT EXISTS), which means:
--   * the schema exists before the first application container connects, so
--     `Base.metadata.create_all()` in app/orders.py never races the database
--     image, and
--   * adding a column here reaches every environment on the next restart
--     instead of only on a fresh volume.
--
-- It must stay in sync with the SQLAlchemy model in srcs/billing-app/app/orders.py.

-- The application role is created and reconciled by init-db.sh from DB_USER.
-- Its password is NEVER written here: it is delivered through a 0600 file that
-- is removed immediately after psql reads it, so it never reaches argv,
-- /proc/<pid>/cmdline or this repository.

-- Ownership of the public schema itself. Without this, tables created by
-- init-db.sh would be owned by `postgres` and the application role could not
-- create or alter anything on a fresh volume.
SELECT format('GRANT ALL ON SCHEMA public TO %I', :'db_user') \gexec

CREATE TABLE IF NOT EXISTS orders (
    id              SERIAL PRIMARY KEY,
    -- INTEGER, not VARCHAR: the consumer coerces the queue payload's user_id
    -- string ("20") to int before the insert (app/validation.py), so literal
    -- SQL such as `SELECT * FROM orders WHERE user_id=20;` works. Must stay
    -- in sync with the SQLAlchemy model in srcs/billing-app/app/orders.py.
    user_id         INTEGER        NOT NULL,
    number_of_items INTEGER        NOT NULL,
    -- NUMERIC(12,2), never DOUBLE PRECISION: money must not accumulate
    -- IEEE-754 rounding drift. This must match `Numeric(12, 2)` in
    -- srcs/billing-app/app/orders.py, otherwise create_all() finds the table
    -- already present and silently keeps money in a float column.
    total_amount    NUMERIC(12, 2) NOT NULL,
    -- TIMESTAMP WITH TIME ZONE matches DateTime(timezone=True) in the model.
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
);

SELECT format('ALTER TABLE orders OWNER TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO %I', :'db_user') \gexec
