/* ============================================================================
   00_setup.sql
   ----------------------------------------------------------------------------
   Purpose : Create the staging table with exact data types and keys, load the
             clean pick data into it, and check that the load succeeded.
   Source  : data/picks_clean.csv, exported by 02_data_cleaning.ipynb (step 9)
   Grain   : one row per pick (one product into one colli during one visit)

   Steps
     1. Create the schema
     2. Create an empty table with data types, keys and rules
     3. Load the data (in Python)
     4. Check the load
     5. Add indexes
     6. Create the analysis view used by all other SQL files

   How to run:
     a. Run steps 1-2 below.
     b. Run the load cell in 02_data_cleaning.ipynb (step 9), which inserts
        the rows into this table.
     c. Run steps 4-6 below.

   Re-running: safe. The table (and the view) are dropped and rebuilt each time,
   so the Python load (b) must be run again after steps 1-2.
   ============================================================================ */


/* ----------------------------------------------------------------------------
   1. Create the schema
   ---------------------------------------------------------------------------- */

-- CREATE SCHEMA IF NOT EXISTS staging;


/* ----------------------------------------------------------------------------
   2. Create an empty table with data types, keys and rules
   Rules are part of the table, so data that breaks them cannot be loaded:
     - PRIMARY KEY : one row per colli and product (the pick definition)
     - NOT NULL    : fields used to join, group or filter must always be filled
     - CHECK       : values that are physically impossible are rejected
   ---------------------------------------------------------------------------- */

-- CASCADE also drops the analysis view, which is recreated in step 6
/* DROP TABLE IF EXISTS staging.picks_clean CASCADE;

CREATE TABLE staging.picks_clean (
    -- identifiers
    colli_id              TEXT          NOT NULL,   -- store order (shipping container)
    product_id            TEXT          NOT NULL,
    picker                TEXT          NOT NULL,
    location              TEXT          NOT NULL,   -- e.g. 10-06-036-1
    aisle                 INTEGER       NOT NULL,
    bay                   INTEGER       NOT NULL,

    -- time
    shift_date            DATE          NOT NULL,   -- evening the shift starts (noon cut-off)
    shift_weekday         TEXT          NOT NULL,
    shift_week            INTEGER       NOT NULL,
    first_finish_time     TIMESTAMP     NOT NULL,   -- finish time of the pick's first line
    finish_time           TIMESTAMP     NOT NULL,   -- finish time of the pick's last line
    start_time            TIMESTAMP,                -- reference only: overlaps the previous pick

    -- measures
    quantity              INTEGER       NOT NULL CHECK (quantity > 0),        -- cases
    volume                NUMERIC(10,3)          CHECK (volume >= 0),         -- exact decimals, no floating-point drift
    n_lines               INTEGER       NOT NULL CHECK (n_lines >= 1),        -- scan lines merged into the pick
    gap_sec               INTEGER                CHECK (gap_sec >= 0),        -- empty for the first pick of a shift
    time_per_pick_sec     INTEGER                CHECK (time_per_pick_sec BETWEEN 0 AND 899),  -- breaks of 15+ min excluded

    -- flags
    holiday_period        BOOLEAN       NOT NULL,
    partial_shift         BOOLEAN       NOT NULL,
    is_regular_picker     BOOLEAN       NOT NULL,
    picker_segment        TEXT          NOT NULL CHECK (picker_segment IN ('core', 'occasional', 'non-regular')),
    has_continuation      BOOLEAN       NOT NULL,
    has_repeat            BOOLEAN       NOT NULL,
    is_after_break        BOOLEAN       NOT NULL,
    is_single_line        BOOLEAN       NOT NULL,
    is_bulk_line          BOOLEAN       NOT NULL,
    is_new_product        BOOLEAN       NOT NULL,
    is_one_shift_product  BOOLEAN       NOT NULL,

    CONSTRAINT pk_picks_clean PRIMARY KEY (colli_id, product_id),
    -- a pick's last line cannot finish before its first line
    CONSTRAINT chk_finish_order CHECK (finish_time >= first_finish_time)
); */


/* ----------------------------------------------------------------------------
   3. Load the data (in Python)
   The rows are inserted from 02_data_cleaning.ipynb (step 9) with
       df.to_sql('picks_clean', engine, schema='staging', if_exists='append', ...)
   - 'append' inserts into this existing table, so the data types, primary key
     and rules defined in step 2 are kept ('replace' would delete them).
   - If any row breaks a rule from step 2, the insert fails.
   - No file path is needed in this script.

   >>> Run the Python load now, then continue with step 4. <<<
   ---------------------------------------------------------------------------- */

select * from staging.picks_clean limit 10;

/* ----------------------------------------------------------------------------
   4. Check the load
   The totals must match the Python validation exactly. If they do not, the
   table was not loaded correctly and nothing else should be run.
   ---------------------------------------------------------------------------- */

-- 4.1 Rows and totals
SELECT
    COUNT(*)                    AS picks,      -- expected 206094
    SUM(quantity)               AS cases,      -- expected 1945575
    SUM(volume)                 AS volume,     -- expected 4373.205
    COUNT(DISTINCT shift_date)  AS shifts,     -- expected 21
    COUNT(DISTINCT picker)      AS pickers,    -- expected 32
    COUNT(DISTINCT colli_id)    AS collis,     -- expected 8368
    COUNT(DISTINCT product_id)  AS products    -- expected 184
FROM staging.picks_clean;

-- 4.2 Missing values: only these columns may have them, each for a known reason
SELECT
    COUNT(*) FILTER (WHERE start_time IS NULL)        AS missing_start_time,     -- expected 85   (reference only)
    COUNT(*) FILTER (WHERE gap_sec IS NULL)           AS missing_gap,            -- expected 361  (first pick of each shift)
    COUNT(*) FILTER (WHERE time_per_pick_sec IS NULL) AS missing_time_per_pick,  -- expected 1093 (first picks, breaks, non-regular users)
    COUNT(*) FILTER (WHERE volume IS NULL)            AS missing_volume          -- expected 0
FROM staging.picks_clean;

-- 4.3 Flags: counts must match the cleaning notes
SELECT
    COUNT(DISTINCT picker)     FILTER (WHERE is_regular_picker)             AS regular_pickers,     -- expected 28
    COUNT(DISTINCT picker)     FILTER (WHERE picker_segment = 'core')       AS core_pickers,        -- expected 21
    COUNT(DISTINCT picker)     FILTER (WHERE picker_segment = 'occasional') AS occasional_pickers,  -- expected 7
    COUNT(DISTINCT shift_date) FILTER (WHERE holiday_period)                AS holiday_shifts,      -- expected 6
    COUNT(DISTINCT shift_date) FILTER (WHERE partial_shift)                 AS partial_shifts,      -- expected 2
    COUNT(DISTINCT colli_id)   FILTER (WHERE is_single_line)                AS single_line_collis,  -- expected 382
    COUNT(*)                   FILTER (WHERE is_bulk_line)                  AS bulk_picks,          -- expected 580
    COUNT(DISTINCT product_id) FILTER (WHERE is_new_product)                AS new_products,        -- expected 5
    COUNT(DISTINCT product_id) FILTER (WHERE is_one_shift_product)          AS one_shift_products   -- expected 3
FROM staging.picks_clean;

-- 4.4 Data types: confirm the table kept the types
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'staging'
  AND table_name   = 'picks_clean'
ORDER BY ordinal_position;


/* ----------------------------------------------------------------------------
   5. Add indexes
   Created after the load, because building an index once on full data is
   faster than updating it for every inserted row.
   ---------------------------------------------------------------------------- */

-- Picker + time: used by every window function that follows a picker through a shift
CREATE INDEX idx_picks_picker_time ON staging.picks_clean (picker, finish_time);
-- Shift, product and aisle: the most common filters and groupings
CREATE INDEX idx_picks_shift   ON staging.picks_clean (shift_date);
CREATE INDEX idx_picks_product ON staging.picks_clean (product_id);
CREATE INDEX idx_picks_aisle   ON staging.picks_clean (aisle);


/* ----------------------------------------------------------------------------
   6. Analysis view
   Fields that every analysis file needs are defined once here, so all files
   use exactly the same definitions.
   ---------------------------------------------------------------------------- */

CREATE SCHEMA IF NOT EXISTS analysis;

CREATE OR REPLACE VIEW analysis.picks AS
SELECT
    p.*,

    -- Clock hour in which the pick was confirmed (21, 22, 23, 0, 1, 2, 3)
    EXTRACT(HOUR FROM p.finish_time)::int                 AS pick_hour,

    -- Hour within the shift, so hours sort in shift order: 21:00 = 0, 22:00 = 1, ... 03:00 = 6
    (EXTRACT(HOUR FROM p.finish_time)::int + 3) % 24      AS hour_of_shift,

    -- Quantity bands: time per pick depends mostly on the visit, not the number of cases,
    -- so comparisons between aisles, products and pickers are made within the same band
    CASE
        WHEN p.quantity = 1               THEN '1'
        WHEN p.quantity BETWEEN 2 AND 5   THEN '2-5'
        WHEN p.quantity BETWEEN 6 AND 12  THEN '6-12'
        WHEN p.quantity BETWEEN 13 AND 56 THEN '13-56'
        ELSE '57+'
    END                                                   AS quantity_band,

    -- Normal shifts: complete and outside the holiday period
    (NOT p.holiday_period AND NOT p.partial_shift)        AS is_normal_shift
FROM staging.picks_clean AS p;

-- Quick check of the view
SELECT hour_of_shift, pick_hour, COUNT(*) AS picks
FROM analysis.picks
GROUP BY hour_of_shift, pick_hour
ORDER BY hour_of_shift;
