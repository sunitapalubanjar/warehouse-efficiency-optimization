/* ============================================================================
   06_star_schema.sql
   ----------------------------------------------------------------------------
   Purpose : Build the star schema used by the Power BI dashboard.
   Source  : analysis.picks (created in 00_setup.sql)
   Schema  : mart (kept separate from the first version's dw schema)

   Model
                       dim_date (shift_date)
                              |
     dim_picker (picker) -- fact_pick -- dim_product (product_id)
                              |
                       dim_hour (hour_of_shift)

     fact_colli: one row per store order, linked to dim_date and dim_picker

   Why a star schema
     - Facts (measurable events) are kept apart from dimensions (descriptions),
       so Power BI can filter any measure by any dimension.
     - Attributes calculated once here (ABC class, size class, shift type)
       are consistent across every visual.

   Grain
     fact_pick  : one row per pick (one product into one colli during one visit)
     fact_colli : one row per colli (store order)

   Re-running: safe. The mart schema is dropped and rebuilt each time.
   ============================================================================ */


DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;


/* ----------------------------------------------------------------------------
   1. dim_date: one row per shift
   shift_type classifies holiday-period shifts into low and peak, using the
   same rule as 05_staffing.sql.
   ---------------------------------------------------------------------------- */

CREATE TABLE mart.dim_date AS
WITH shift_volume AS (
    SELECT
        shift_date,
        MAX(shift_weekday)                                           AS weekday,
        MAX(shift_week)                                              AS iso_week,
        BOOL_OR(holiday_period)                                      AS is_holiday_period,
        BOOL_OR(partial_shift)                                       AS is_partial_shift,
        COUNT(*)                                                     AS picks
    FROM analysis.picks
    GROUP BY shift_date
),
normal_avg AS (
    SELECT AVG(picks) AS avg_picks
    FROM shift_volume
    WHERE NOT is_holiday_period AND NOT is_partial_shift
)
SELECT
    s.shift_date,
    s.weekday,
    EXTRACT(ISODOW FROM s.shift_date)::int                           AS weekday_number,   -- 1 = Monday, for sorting
    s.iso_week,
    s.is_holiday_period,
    s.is_partial_shift,
    CASE
        WHEN s.is_partial_shift      THEN 'partial'
        WHEN NOT s.is_holiday_period THEN 'normal'
        WHEN s.picks < n.avg_picks   THEN 'low'
        ELSE 'peak'
    END                                                              AS shift_type
FROM shift_volume AS s
CROSS JOIN normal_avg AS n;

ALTER TABLE mart.dim_date ADD PRIMARY KEY (shift_date);


/* ----------------------------------------------------------------------------
   2. dim_hour: one row per hour of the shift
   hour_of_shift sorts the night in order (21:00 = 0 ... 03:00 = 6).
   ---------------------------------------------------------------------------- */

CREATE TABLE mart.dim_hour AS
SELECT DISTINCT
    hour_of_shift,
    pick_hour,
    LPAD(pick_hour::text, 2, '0') || ':00'                           AS clock_hour,
    hour_of_shift BETWEEN 0 AND 6                                    AS is_night_shift_hour
FROM analysis.picks;

ALTER TABLE mart.dim_hour ADD PRIMARY KEY (hour_of_shift);


/* ----------------------------------------------------------------------------
   3. dim_picker: one row per picker
   ---------------------------------------------------------------------------- */

CREATE TABLE mart.dim_picker AS
SELECT
    picker,
    MAX(picker_segment)                                              AS picker_segment,
    BOOL_OR(is_regular_picker)                                       AS is_regular_picker,
    COUNT(DISTINCT shift_date)                                       AS shifts_worked,
    MIN(shift_date)                                                  AS first_shift,
    MAX(shift_date)                                                  AS last_shift
FROM analysis.picks
GROUP BY picker;

ALTER TABLE mart.dim_picker ADD PRIMARY KEY (picker);


/* ----------------------------------------------------------------------------
   4. dim_product: one row per product (and its location)
   - abc_class      : A = first 80% of picks, B = next 15%, C = last 5%
   - size_class     : products split into three equal groups by median volume
                      per case (small, medium, bulky), used to compare like with like
   - split_rate_pct : share of picks with a continuation line
   - is_comparable  : enough data for product comparisons
                      (100+ picks, not new, not picked in only one shift)
   ---------------------------------------------------------------------------- */

CREATE TABLE mart.dim_product AS
WITH product_stats AS (
    SELECT
        product_id,
        MAX(location)                                                AS location,
        MAX(aisle)                                                   AS aisle,
        MAX(bay)                                                     AS bay,
        COUNT(*)                                                     AS picks,
        COUNT(*) FILTER (WHERE has_continuation)                     AS split_picks,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY volume / quantity) AS volume_per_case,
        BOOL_OR(is_new_product)                                      AS is_new_product,
        BOOL_OR(is_one_shift_product)                                AS is_one_shift_product
    FROM analysis.picks
    GROUP BY product_id
)
SELECT
    product_id,
    location,
    aisle,
    bay,
    picks,
    CASE
        WHEN (SUM(picks) OVER (ORDER BY picks DESC, product_id) - picks)
             * 100.0 / SUM(picks) OVER () < 80 THEN 'A'
        WHEN (SUM(picks) OVER (ORDER BY picks DESC, product_id) - picks)
             * 100.0 / SUM(picks) OVER () < 95 THEN 'B'
        ELSE 'C'
    END                                                              AS abc_class,
    ROUND(volume_per_case::numeric, 4)                               AS volume_per_case,
    CASE NTILE(3) OVER (ORDER BY volume_per_case)
        WHEN 1 THEN 'small'
        WHEN 2 THEN 'medium'
        ELSE 'bulky'
    END                                                              AS size_class,
    ROUND(100.0 * split_picks / picks, 1)                            AS split_rate_pct,
    is_new_product,
    is_one_shift_product,
    (picks >= 100 AND NOT is_new_product AND NOT is_one_shift_product) AS is_comparable
FROM product_stats;

ALTER TABLE mart.dim_product ADD PRIMARY KEY (product_id);


/* ----------------------------------------------------------------------------
   5. fact_pick: one row per pick
   is_changeover marks the first pick of a new colli in a picker's shift
   (its time includes finishing the previous order), used in the process page.
   ---------------------------------------------------------------------------- */

CREATE TABLE mart.fact_pick AS
SELECT
    colli_id,
    product_id,
    picker,
    shift_date,
    hour_of_shift,
    finish_time,
    quantity,
    quantity_band,
    volume,
    n_lines,
    time_per_pick_sec,
    has_continuation,
    is_bulk_line,
    is_single_line,
    is_after_break,
    is_normal_shift,
    COALESCE(colli_id <> LAG(colli_id) OVER (PARTITION BY picker, shift_date ORDER BY finish_time),
             TRUE)                                                   AS is_changeover
FROM analysis.picks;

ALTER TABLE mart.fact_pick ADD PRIMARY KEY (colli_id, product_id);
ALTER TABLE mart.fact_pick ADD FOREIGN KEY (shift_date)    REFERENCES mart.dim_date    (shift_date);
ALTER TABLE mart.fact_pick ADD FOREIGN KEY (hour_of_shift) REFERENCES mart.dim_hour    (hour_of_shift);
ALTER TABLE mart.fact_pick ADD FOREIGN KEY (picker)        REFERENCES mart.dim_picker  (picker);
ALTER TABLE mart.fact_pick ADD FOREIGN KEY (product_id)    REFERENCES mart.dim_product (product_id);


/* ----------------------------------------------------------------------------
   6. fact_colli: one row per colli (store order)
   aisle_changes counts how often the picker switched aisle within the order
   (proxy for travel). Colli duration is only meaningful for collis with more
   than one pick.
   ---------------------------------------------------------------------------- */

CREATE TABLE mart.fact_colli AS
WITH sequence AS (
    SELECT
        colli_id,
        picker,
        shift_date,
        aisle,
        quantity,
        first_finish_time,
        finish_time,
        LAG(aisle) OVER (PARTITION BY colli_id ORDER BY finish_time) AS previous_aisle
    FROM analysis.picks
)
SELECT
    colli_id,
    MAX(picker)                                                      AS picker,
    MAX(shift_date)                                                  AS shift_date,
    COUNT(*)                                                         AS picks,
    SUM(quantity)                                                    AS cases,
    COUNT(DISTINCT aisle)                                            AS aisles_visited,
    COUNT(*) FILTER (WHERE aisle <> previous_aisle)                  AS aisle_changes,
    MIN(first_finish_time)                                           AS first_pick_time,
    MAX(finish_time)                                                 AS last_pick_time,
    EXTRACT(EPOCH FROM MAX(finish_time) - MIN(first_finish_time))::int AS colli_duration_sec,
    COUNT(*) = 1                                                     AS is_single_line
FROM sequence
GROUP BY colli_id;

ALTER TABLE mart.fact_colli ADD PRIMARY KEY (colli_id);
ALTER TABLE mart.fact_colli ADD FOREIGN KEY (shift_date) REFERENCES mart.dim_date   (shift_date);
ALTER TABLE mart.fact_colli ADD FOREIGN KEY (picker)     REFERENCES mart.dim_picker (picker);


/* ----------------------------------------------------------------------------
   7. Check the star schema
   Row counts per table, and the fact table must keep every pick and case.
   ---------------------------------------------------------------------------- */

SELECT 'dim_date'    AS table_name, COUNT(*) AS rows FROM mart.dim_date      -- expected 21
UNION ALL SELECT 'dim_hour',    COUNT(*) FROM mart.dim_hour                  -- expected 8 (21:00-03:00, plus 15:00 for the afternoon order)
UNION ALL SELECT 'dim_picker',  COUNT(*) FROM mart.dim_picker                -- expected 32
UNION ALL SELECT 'dim_product', COUNT(*) FROM mart.dim_product               -- expected 184
UNION ALL SELECT 'fact_pick',   COUNT(*) FROM mart.fact_pick                 -- expected 206094
UNION ALL SELECT 'fact_colli',  COUNT(*) FROM mart.fact_colli;               -- expected 8368

SELECT
    (SELECT SUM(quantity) FROM mart.fact_pick)                       AS cases_in_fact_pick,    -- expected 1945575
    (SELECT SUM(cases)    FROM mart.fact_colli)                      AS cases_in_fact_colli;   -- expected 1945575
