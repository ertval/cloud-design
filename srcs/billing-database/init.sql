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
    -- SQL such as `SELECT * FROM orders WHERE user_id=20;` works. Must stay in
    -- sync with `Column(Integer, nullable=False)` in
    -- srcs/billing-app/app/orders.py; a String(255) there would be a silent
    -- mismatch, because create_all() finds this table already present and keeps
    -- whatever type is here.
    user_id         INTEGER        NOT NULL,
    number_of_items INTEGER        NOT NULL,
    -- NUMERIC(12,2), never DOUBLE PRECISION: money must not accumulate
    -- IEEE-754 rounding drift. This must match `Numeric(12, 2)` in
    -- srcs/billing-app/app/orders.py, otherwise create_all() finds the table
    -- already present and silently keeps money in a float column.
    total_amount    NUMERIC(12, 2) NOT NULL,
    -- TIMESTAMP WITH TIME ZONE matches DateTime(timezone=True) in the model.
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Reconcile the column TYPES on an already-existing table.
--
-- CREATE TABLE IF NOT EXISTS is idempotent for *creating* a table, but it does
-- nothing when the table already exists with different column types -- so on
-- any volume created before these types were introduced, the table silently
-- kept the old definitions while the application carried on writing into them.
-- That was observed live: on a 5-week-old volume `user_id` was
-- `character varying` and `total_amount` was `double precision`, even though
-- this file and app/orders.py both declare INTEGER / NUMERIC(12,2). The
-- gateway's strict-int coercion of user_id was therefore pointless, and money
-- sat in an IEEE-754 float column -- exactly the drift NUMERIC(12,2) exists to
-- prevent. `WHERE user_id = 20` also failed, with "operator does not exist:
-- character varying = integer".
--
-- So the types are asserted, not assumed. Each ALTER is guarded by a
-- comparison against information_schema, which keeps this a no-op once the
-- schema is correct.
-- Money first: safe on any existing data.
DO $$
DECLARE
    coltype text;
BEGIN
SELECT data_type INTO coltype FROM information_schema.columns
 WHERE table_schema = current_schema() AND table_name = 'orders'
   AND column_name = 'total_amount';
IF coltype IS NOT NULL AND coltype <> 'numeric' THEN
    RAISE NOTICE 'orders.total_amount is %, converting to numeric(12,2)', coltype;
    EXECUTE 'ALTER TABLE orders ALTER COLUMN total_amount TYPE numeric(12,2) '
         || 'USING total_amount::numeric(12,2)';
END IF;
END $$;

-- Then the timestamp: safe, treating legacy values as UTC wall-clock.
DO $$
DECLARE
    coltype text;
BEGIN
SELECT data_type INTO coltype FROM information_schema.columns
 WHERE table_schema = current_schema() AND table_name = 'orders'
   AND column_name = 'created_at';
IF coltype IS NOT NULL AND coltype <> 'timestamp with time zone' THEN
    -- The old column was TIMESTAMP WITHOUT TIME ZONE and the container
    -- ran UTC, so the stored values are UTC wall-clock; labelling them as
    -- such is correct rather than a silent assumption.
    RAISE NOTICE 'orders.created_at is %, converting to timestamptz', coltype;
    EXECUTE 'ALTER TABLE orders ALTER COLUMN created_at TYPE timestamp with time zone '
         || 'USING created_at AT TIME ZONE ''UTC''';
END IF;
END $$;

-- Deliberately last, and in its own block so it commits independently.
DO $$
DECLARE
    coltype text;
BEGIN
SELECT data_type INTO coltype FROM information_schema.columns
 WHERE table_schema = current_schema() AND table_name = 'orders'
   AND column_name = 'user_id';
-- Deliberately LAST. This is the only conversion that can fail on existing
-- data, and with ON_ERROR_STOP=1 a failure here would otherwise prevent the
-- two safe conversions above from being applied at all.
IF coltype IS NOT NULL AND coltype <> 'integer' THEN
    -- No USING fallback that swallows bad data: if a pre-existing row
    -- holds a non-numeric user_id this raises, which is the correct
    -- outcome. Quietly discarding or nulling a customer id is not.
    RAISE NOTICE 'orders.user_id is %, converting to integer', coltype;
    EXECUTE 'ALTER TABLE orders ALTER COLUMN user_id TYPE integer '
         || 'USING user_id::integer';
END IF;
END $$;

SELECT format('ALTER TABLE orders OWNER TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO %I', :'db_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO %I', :'db_user') \gexec
