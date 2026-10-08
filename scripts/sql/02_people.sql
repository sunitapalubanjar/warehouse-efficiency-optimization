/* ============================================================================
   02_people.sql
   ----------------------------------------------------------------------------
   BQ2  People: how much do pickers differ, and does experience explain it?

   Why  If the gaps between pickers are large, training and staffing are the
        lever. Comparisons must be fair: only regular pickers, rates instead of
        totals, and core and occasional pickers compared separately.

   Hypothesis
        H2: occasional pickers are slower, and the gap narrows with each shift
            worked (learning curve).

   Source  analysis.picks (created in 00_setup.sql)
   Scope   Regular pickers only (time_per_pick_sec is empty for others).
           Normal shifts only in 2.1-2.3, so the holiday period does not
           distort the comparison. This shows 27 of the 28 regular pickers:
           one occasional picker worked only holiday and partial shifts.

   Queries
     2.1 KPIs and ranking per picker
     2.2 Spread between pickers, by segment
     2.3 Core vs occasional within the same quantity band
     2.4 Learning curve: productivity by shift number (H2)

   Findings: (write after running the queries)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   2.1 KPIs and ranking per picker
   RANK orders pickers by picks per hour; NTILE(4) splits them into quartiles
   (1 = fastest 25%). Shown as a distribution, not as a "league table":
   the goal is to understand the spread, not to blame individuals.
   ---------------------------------------------------------------------------- */

WITH picker_kpis AS (
    SELECT
        picker,
        picker_segment,
        COUNT(DISTINCT shift_date)                                   AS shifts,
        COUNT(time_per_pick_sec)                                     AS timed_picks,
        SUM(time_per_pick_sec) / 3600.0                              AS working_hours,
        COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0)              AS picks_per_hour,
        SUM(quantity) FILTER (WHERE time_per_pick_sec IS NOT NULL)
            / (SUM(time_per_pick_sec) / 3600.0)                      AS cases_per_hour,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec) AS median_sec_per_pick
    FROM analysis.picks
    WHERE is_regular_picker
      AND is_normal_shift
    GROUP BY picker, picker_segment
)
SELECT
    RANK()  OVER (ORDER BY picks_per_hour DESC)                      AS rank_picks_per_hour,
    NTILE(4) OVER (ORDER BY picks_per_hour DESC)                     AS quartile,
    picker,
    picker_segment,
    shifts,
    timed_picks,
    ROUND(working_hours::numeric, 1)                                 AS working_hours,
    ROUND(picks_per_hour::numeric, 1)                                AS picks_per_hour,
    ROUND(cases_per_hour::numeric, 1)                                AS cases_per_hour,
    median_sec_per_pick
FROM picker_kpis
ORDER BY rank_picks_per_hour;


/* ----------------------------------------------------------------------------
   2.2 Spread between pickers, by segment
   Quartiles across pickers show how wide the gap is. The ratio between the
   fastest and slowest picker shows the size of the opportunity.
   ---------------------------------------------------------------------------- */

WITH picker_kpis AS (
    SELECT
        picker,
        picker_segment,
        COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0) AS picks_per_hour
    FROM analysis.picks
    WHERE is_regular_picker
      AND is_normal_shift
    GROUP BY picker, picker_segment
)
SELECT
    COALESCE(picker_segment, 'all regular')                          AS segment,
    COUNT(*)                                                         AS pickers,
    ROUND(MIN(picks_per_hour)::numeric, 1)                           AS min_pph,
    ROUND((percentile_cont(0.25) WITHIN GROUP (ORDER BY picks_per_hour))::numeric, 1) AS p25_pph,
    ROUND((percentile_cont(0.50) WITHIN GROUP (ORDER BY picks_per_hour))::numeric, 1) AS median_pph,
    ROUND((percentile_cont(0.75) WITHIN GROUP (ORDER BY picks_per_hour))::numeric, 1) AS p75_pph,
    ROUND(MAX(picks_per_hour)::numeric, 1)                           AS max_pph,
    ROUND((MAX(picks_per_hour) / MIN(picks_per_hour))::numeric, 2)   AS fastest_vs_slowest
FROM picker_kpis
GROUP BY ROLLUP (picker_segment)          -- one row per segment plus a total row
ORDER BY segment;


/* ----------------------------------------------------------------------------
   2.3 Core vs occasional within the same quantity band
   Occasional pickers may receive different orders. Comparing within the same
   quantity band removes that difference, so a remaining gap is about speed.
   ---------------------------------------------------------------------------- */

SELECT
    quantity_band,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)
        FILTER (WHERE picker_segment = 'core')                       AS core_median_sec,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)
        FILTER (WHERE picker_segment = 'occasional')                 AS occasional_median_sec,
    COUNT(time_per_pick_sec) FILTER (WHERE picker_segment = 'core')       AS core_picks,
    COUNT(time_per_pick_sec) FILTER (WHERE picker_segment = 'occasional') AS occasional_picks
FROM analysis.picks
WHERE is_regular_picker
  AND is_normal_shift
GROUP BY quantity_band
ORDER BY MIN(quantity);


/* ----------------------------------------------------------------------------
   2.4 Learning curve: productivity by shift number (H2)
   DENSE_RANK numbers each picker's shifts in date order (1 = first shift in
   the data). If occasional pickers learn, their picks per hour should rise
   with the shift number. Partial shifts are excluded; holiday shifts are kept,
   because otherwise occasional pickers would have too few shifts.
   Note: shift 1 is the first shift in the data, not necessarily the picker's
   first shift ever.
   ---------------------------------------------------------------------------- */

WITH numbered AS (
    SELECT
        picker,
        picker_segment,
        shift_date,
        time_per_pick_sec,
        DENSE_RANK() OVER (PARTITION BY picker ORDER BY shift_date)  AS shift_number
    FROM analysis.picks
    WHERE is_regular_picker
      AND NOT partial_shift
)
SELECT
    picker_segment,
    shift_number,
    COUNT(DISTINCT picker)                                           AS pickers,
    ROUND(COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0), 1)       AS picks_per_hour,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)   AS median_sec_per_pick
FROM numbered
WHERE shift_number <= 6                    -- occasional pickers worked at most 6 shifts
GROUP BY picker_segment, shift_number
ORDER BY picker_segment, shift_number;
