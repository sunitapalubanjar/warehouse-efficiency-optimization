/* ============================================================================
   01_baseline.sql
   ----------------------------------------------------------------------------
   BQ1  Baseline: how productive is the night shift today?

   Why  Every other finding (people, layout, process, staffing) is compared
        with this baseline. "What limits productivity" needs a normal level first.

   Hypothesis
        H1: productivity drops in the last hours of the shift
            (fatigue, or the end-of-shift rush before dispatch).

   Source  analysis.picks (created in 00_setup.sql)

   KPI definitions (used in every file)
     - Timed picks   : picks with a time_per_pick_sec (regular pickers only,
                       breaks of 15+ min and the first pick of each shift excluded)
     - Working hours : SUM(time_per_pick_sec) / 3600
     - Picks per hour: timed picks / working hours   (primary productivity KPI)
     - Cases per hour: cases of timed picks / working hours (output KPI)
     - Time per pick : median of time_per_pick_sec (median, because the
                       distribution is right-skewed)

   Queries
     1.1 Overall KPIs
     1.2 KPIs per shift
     1.3 How stable are normal shifts?
     1.4 KPIs by hour of the shift (H1)
     1.5 Time per pick by quantity band

   Findings: (write after running the queries)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   1.1 Overall KPIs
   The headline numbers of the night shift over the whole period.
   ---------------------------------------------------------------------------- */

SELECT
    COUNT(*)                                                         AS total_picks,
    SUM(quantity)                                                    AS total_cases,
    COUNT(time_per_pick_sec)                                         AS timed_picks,
    ROUND(SUM(time_per_pick_sec) / 3600.0, 1)                        AS working_hours,
    ROUND(COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0), 1)        AS picks_per_hour,
    ROUND(SUM(quantity) FILTER (WHERE time_per_pick_sec IS NOT NULL)
          / (SUM(time_per_pick_sec) / 3600.0), 1)                    AS cases_per_hour,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)   AS median_sec_per_pick,
    percentile_cont(0.9) WITHIN GROUP (ORDER BY time_per_pick_sec)   AS p90_sec_per_pick
FROM analysis.picks;


/* ----------------------------------------------------------------------------
   1.2 KPIs per shift
   Shift type separates normal shifts from the holiday period and the two
   partial shifts, which are not comparable with normal shifts.
   ---------------------------------------------------------------------------- */

SELECT
    shift_date,
    shift_weekday,
    CASE
        WHEN partial_shift  THEN 'partial'
        WHEN holiday_period THEN 'holiday'
        ELSE 'normal'
    END                                                              AS shift_type,
    COUNT(DISTINCT picker) FILTER (WHERE is_regular_picker)          AS pickers,
    COUNT(*)                                                         AS picks,
    ROUND(SUM(time_per_pick_sec) / 3600.0, 1)                        AS working_hours,
    ROUND(COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0), 1)        AS picks_per_hour,
    ROUND(SUM(quantity) FILTER (WHERE time_per_pick_sec IS NOT NULL)
          / (SUM(time_per_pick_sec) / 3600.0), 1)                    AS cases_per_hour,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)   AS median_sec_per_pick
FROM analysis.picks
GROUP BY shift_date, shift_weekday, partial_shift, holiday_period
ORDER BY shift_date;


/* ----------------------------------------------------------------------------
   1.3 How stable are normal shifts?
   A CTE calculates picks per hour per shift; the outer query summarises the
   spread across normal shifts. A small spread means a reliable baseline.
   ---------------------------------------------------------------------------- */

WITH shift_kpis AS (
    SELECT
        shift_date,
        COUNT(*)                                                     AS picks,
        COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0)              AS picks_per_hour
    FROM analysis.picks
    WHERE is_normal_shift
    GROUP BY shift_date
)
SELECT
    COUNT(*)                                     AS normal_shifts,
    ROUND(AVG(picks), 0)                         AS avg_picks_per_shift,
    ROUND(MIN(picks_per_hour), 1)                AS min_picks_per_hour,
    ROUND(AVG(picks_per_hour), 1)                AS avg_picks_per_hour,
    ROUND(MAX(picks_per_hour), 1)                AS max_picks_per_hour,
    -- coefficient of variation: spread relative to the average (lower = more stable)
    ROUND(STDDEV(picks_per_hour) / AVG(picks_per_hour) * 100, 1) AS cv_percent
FROM shift_kpis;


/* ----------------------------------------------------------------------------
   1.4 KPIs by hour of the shift (H1)
   Normal shifts only, so the holiday period does not distort the hours.
   hour_of_shift 0 = 21:00 ... 6 = 03:00. A window function compares each hour
   with the average of all hours.
   ---------------------------------------------------------------------------- */

WITH hourly AS (
    SELECT
        hour_of_shift,
        pick_hour,
        COUNT(*)                                                     AS picks,
        COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0)              AS picks_per_hour,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec) AS median_sec_per_pick
    FROM analysis.picks
    WHERE is_normal_shift
      AND hour_of_shift BETWEEN 0 AND 6          -- the night shift, 21:00 to 03:59
    GROUP BY hour_of_shift, pick_hour
)
SELECT
    hour_of_shift,
    LPAD(pick_hour::text, 2, '0') || ':00'                           AS clock_hour,
    picks,
    ROUND(100.0 * picks / SUM(picks) OVER (), 1)                     AS share_of_picks_pct,
    ROUND(picks_per_hour::numeric, 1)                                AS picks_per_hour,
    -- difference from the average hour: negative = slower than usual
    ROUND((picks_per_hour - AVG(picks_per_hour) OVER ())::numeric, 1) AS vs_avg_hour,
    median_sec_per_pick
FROM hourly
ORDER BY hour_of_shift;


/* ----------------------------------------------------------------------------
   1.5 Time per pick by quantity band
   Shows whether picking time is driven by the visit (walking + scanning) or
   by the number of cases. This is why lines per hour is the primary KPI.
   ---------------------------------------------------------------------------- */

SELECT
    quantity_band,
    COUNT(*)                                                         AS picks,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)   AS median_sec_per_pick,
    ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)
          / percentile_cont(0.5) WITHIN GROUP (ORDER BY quantity))::numeric, 2) AS median_sec_per_case
FROM analysis.picks
WHERE time_per_pick_sec IS NOT NULL
GROUP BY quantity_band
ORDER BY MIN(quantity);
