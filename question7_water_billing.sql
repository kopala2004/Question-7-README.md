-- =====================================================================
-- ICT371 Advanced Database
-- Question 7: Water Meter Readings and Billing   (PostgreSQL)
-- Tariff: first 10 units K5 each, units above 10 K8 each, zero = K0
-- Run top to bottom. The script is re-runnable (drops objects first).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Clean start
-- ---------------------------------------------------------------------
DROP VIEW      IF EXISTS v_overdue_bills;
DROP TABLE     IF EXISTS receivable_snapshot;
DROP TABLE     IF EXISTS bills;
DROP TABLE     IF EXISTS readings;
DROP TABLE     IF EXISTS customers;
DROP FUNCTION  IF EXISTS fn_water_charge(NUMERIC);
DROP FUNCTION  IF EXISTS trg_check_reading();
DROP PROCEDURE IF EXISTS pr_generate_bill(INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_receivables();

-- =====================================================================
-- (a) DATABASE AND TABLES
-- =====================================================================
CREATE TABLE customers (
    customer_id SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL        PRIMARY KEY,
    customer_id      INT           NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL,
    current_reading  NUMERIC(10,2) NOT NULL,
    CONSTRAINT uq_customer_month   UNIQUE (customer_id, reading_month),
    CONSTRAINT ck_prev_nonneg      CHECK (previous_reading >= 0),
    CONSTRAINT ck_curr_nonneg      CHECK (current_reading  >= 0),
    -- reading_month must be the first day of a month
    CONSTRAINT ck_month_start      CHECK (reading_month = date_trunc('month', reading_month)::date)
);

CREATE TABLE bills (
    bill_id     SERIAL        PRIMARY KEY,
    reading_id  INT           NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10,2) NOT NULL,
    amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_charge_nonneg CHECK (charge >= 0),
    CONSTRAINT ck_paid_range    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE          PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL CHECK (total_due >= 0)
);

-- =====================================================================
-- (b) FUNCTION: fn_water_charge
--     Band 1: first 10 units x K5 ; Band 2: units above 10 x K8
-- =====================================================================
CREATE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_charge NUMERIC;
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative (got %)', p_units;
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := 10 * 5 + (p_units - 10) * 8;
    END IF;

    RETURN ROUND(v_charge, 2);          -- exact two-decimal charge
END;
$$;

-- =====================================================================
-- (d) TRIGGER on readings (installed BEFORE seed data is loaded)
--     Rejects current_reading < previous_reading, even for direct SQL.
--     BEFORE trigger raising an exception => row is never stored.
-- =====================================================================
CREATE FUNCTION trg_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
            'Invalid reading: current_reading (%) is below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_check_reading();

-- =====================================================================
-- (c) PROCEDURE: pr_generate_bill
-- =====================================================================
CREATE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC;
    v_curr   NUMERIC;
    v_units  NUMERIC;
    v_charge NUMERIC(10,2);
BEGIN
    IF p_reading_id IS NULL OR p_due_on IS NULL THEN
        RAISE EXCEPTION 'Reading ID and due date are required';
    END IF;

    -- Unknown reading?
    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading ID: %', p_reading_id;
    END IF;

    -- Reading already billed?
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    -- Derive consumption and use the function for the charge
    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- =====================================================================
-- (a, continued) SEED DATA
--   3 customers, 6 readings: zero, exactly 10, and above 10 units
-- =====================================================================
INSERT INTO customers (full_name) VALUES
    ('Chanda Mwila'),
    ('Mutale Banda'),
    ('Tendai Phiri');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100,  100),   -- 0 units   -> K0
    (1, DATE '2026-10-01', 100,  110),   -- 10 units  -> K50
    (2, DATE '2026-09-01',  50,   65),   -- 15 units  -> K90
    (2, DATE '2026-10-01',  65,   72),   -- 7 units   -> K35
    (3, DATE '2026-09-01',   0,   25),   -- 25 units  -> K170
    (3, DATE '2026-10-01',  25,   35);   -- 10 units  -> K50

-- Generate bills through the procedure (September bills overdue,
-- October bills for readings 4 and 6 not yet due)
CALL pr_generate_bill(1, DATE '2026-10-15');
CALL pr_generate_bill(2, DATE '2026-11-15');
CALL pr_generate_bill(3, DATE '2026-10-15');
CALL pr_generate_bill(4, DATE '2026-12-15');
CALL pr_generate_bill(5, DATE '2026-10-15');
CALL pr_generate_bill(6, DATE '2026-12-15');

-- Some payments (bill 2 fully paid, bill 3 partly paid)
UPDATE bills SET amount_paid = charge WHERE bill_id = 2;
UPDATE bills SET amount_paid = 40     WHERE bill_id = 3;

-- =====================================================================
-- (e) VIEW: v_overdue_bills
-- =====================================================================
CREATE VIEW v_overdue_bills AS
SELECT  c.full_name,
        b.due_on,
        (b.charge - b.amount_paid) AS outstanding_amount
FROM    bills     b
JOIN    readings  r ON r.reading_id  = b.reading_id
JOIN    customers c ON c.customer_id = r.customer_id
WHERE   b.due_on < CURRENT_DATE
  AND   b.amount_paid < b.charge;

-- =====================================================================
-- (f) INDEX: partial index on due_on for unpaid bills only
--     Justification: overdue searches filter on due_on and only look at
--     bills not fully paid. Fully paid bills (the majority over time)
--     are excluded, so the index stays small and a range scan on due_on
--     is fast. The predicate matches the unpaid-bill condition exactly.
-- =====================================================================
CREATE INDEX idx_bills_unpaid_due_on
    ON bills (due_on)
    WHERE amount_paid < charge;

ANALYZE bills;

-- With only six rows the planner prefers a sequential scan, so it is
-- disabled for this session purely to demonstrate index use.
SET enable_seqscan = off;

EXPLAIN
SELECT bill_id, due_on, (charge - amount_paid) AS outstanding
FROM   bills
WHERE  amount_paid < charge
  AND  due_on < CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) PROCEDURE + SCHEDULED JOB: pr_refresh_receivables
--     UPSERT => re-running replaces the same date's total (no doubling)
-- =====================================================================
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE,
           COALESCE(SUM(charge - amount_paid), 0)
    FROM   bills
    WHERE  amount_paid < charge
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

-- Schedule daily at 00:30 using the pg_cron extension
-- (requires pg_cron in shared_preload_libraries; run as a superuser
--  or the database owner permitted to use cron).
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_receivables_daily',        -- job name (re-running updates it)
    '30 0 * * *',                       -- minute 30, hour 0, every day
    $$CALL pr_refresh_receivables()$$
);

-- Inspect the job and its run history:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC;

-- ---------------------------------------------------------------------
-- If pg_cron is NOT available, use pgAgent (or the OS cron) to run
-- "CALL pr_refresh_receivables();" daily at 00:30.
-- ---------------------------------------------------------------------

-- =====================================================================
-- TESTS / DEMONSTRATION
-- =====================================================================

-- Function: tariff bands
SELECT fn_water_charge(0)    AS zero_units,      -- 0.00
       fn_water_charge(10)   AS ten_units,       -- 50.00
       fn_water_charge(15)   AS fifteen_units,   -- 90.00
       fn_water_charge(12.5) AS decimal_units;   -- 50 + 2.5*8 = 70.00

-- Function: invalid input (each should raise an exception)
-- SELECT fn_water_charge(NULL);
-- SELECT fn_water_charge(-3);

-- Bills generated through the procedure
SELECT b.bill_id, c.full_name, r.reading_month,
       (r.current_reading - r.previous_reading) AS units,
       b.charge, b.amount_paid, b.due_on
FROM   bills b
JOIN   readings  r ON r.reading_id  = b.reading_id
JOIN   customers c ON c.customer_id = r.customer_id
ORDER  BY b.bill_id;

-- Procedure: unknown reading / duplicate bill (should raise exceptions)
-- CALL pr_generate_bill(999, DATE '2026-12-31');
-- CALL pr_generate_bill(1,   DATE '2026-12-31');

-- Trigger: rejected reading is not stored
DO $$
BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (1, DATE '2026-11-01', 110, 100);   -- current below previous
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END;
$$;

SELECT COUNT(*) AS readings_for_nov_2026
FROM   readings
WHERE  reading_month = DATE '2026-11-01';      -- 0 rows stored

-- View
SELECT * FROM v_overdue_bills ORDER BY due_on;

-- Scheduled procedure: run twice, total must not double
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;             -- one row for today
