/* ============================================================================
   05_staffing.sql
   ----------------------------------------------------------------------------
   BQ5  Workload and staffing: does staffing match the workload?

   Why  Store orders are ready on time only if there are enough pickers for the
        volume. The holiday period gives the only low- and peak-volume shifts
        in the data, so it shows how the operation reacts to volume changes.

   Hypothesis
        H5: on peak shifts, extra pickers are added but productivity per picker
            falls (more congestion, more new staff).

   Source  analysis.picks (created in 00_setup.sql)

   Shift types
     - normal  : complete shifts outside the holiday period
     - low     : holiday-period shifts with fewer picks than the normal average
     - peak    : holiday-period shifts with more picks than the normal average
     - partial : first and last shift (only half in the data); excluded from
                 comparisons

   Caution
     There are only 2 peak shifts and 4 low shifts, so differences are an
     indication, not proof.

   Queries
     5.1 Workload and staffing per shift
     5.2 Normal vs low vs peak shifts (H5)
     5.3 How do pickers and productivity move with volume?

   Findings: (write after running the queries)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   5.1 Workload and staffing per shift
   The normal-shift average is calculated once (CTE) and used to classify the
   holiday-period shifts into low and peak.
   ---------------------------------------------------------------------------- */

WITH shift_kpis AS (
    SELECT
        shift_date,
        shift_weekday,
        holiday_period,
        partial_shift,
        COUNT(*)                                                     AS picks,
        SUM(quantity)                                                AS cases,
        COUNT(DISTINCT picker) FILTER (WHERE is_regular_picker)      AS pickers,
        COUNT(DISTINCT picker) FILTER (WHERE picker_segment = 'occasional') AS occasional_pickers,
        SUM(time_per_pick_sec) / 3600.0                              AS working_hours,
        COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0)              AS picks_per_hour
    FROM analysis.picks
    GROUP BY shift_date, shift_weekday, holiday_period, partial_shift
),
normal_avg AS (
    SELECT AVG(picks) AS avg_picks
    FROM shift_kpis
    WHERE NOT holiday_period AND NOT partial_shift
)
SELECT
    s.shift_date,
    s.shift_weekday,
    CASE
        WHEN s.partial_shift                    THEN 'partial'
        WHEN NOT s.holiday_period               THEN 'normal'
        WHEN s.picks < n.avg_picks              THEN 'low'
        ELSE 'peak'
    END                                                              AS shift_type,
    s.picks,
    ROUND(100.0 * s.picks / n.avg_picks, 0)                          AS pct_of_normal_volume,
    s.pickers,
    s.occasional_pickers,
    ROUND(1.0 * s.picks / s.pickers, 0)                              AS picks_per_picker,
    ROUND(s.working_hours::numeric, 1)                               AS working_hours,
    ROUND(s.picks_per_hour::numeric, 1)                              AS picks_per_hour
FROM shift_kpis AS s
CROSS JOIN normal_avg AS n
ORDER BY s.shift_date;


/* ----------------------------------------------------------------------------
   5.2 Normal vs low vs peak shifts (H5)
   Two levels are kept apart, so neither is distorted:
     - per-shift figures (picks, pickers) are averaged over shifts
     - per-pick figures (picks per hour, median time) are calculated from all
       timed picks of each shift type, so larger shifts weigh more
   ---------------------------------------------------------------------------- */

WITH shift_kpis AS (
    SELECT
        shift_date,
        holiday_period,
        partial_shift,
        COUNT(*)                                                     AS picks,
        COUNT(DISTINCT picker) FILTER (WHERE is_regular_picker)      AS pickers,
        COUNT(*) FILTER (WHERE picker_segment = 'occasional')        AS occasional_picks,
        COUNT(time_per_pick_sec)                                     AS timed_picks,
        SUM(time_per_pick_sec)                                       AS timed_seconds
    FROM analysis.picks
    GROUP BY shift_date, holiday_period, partial_shift
),
typed AS (
    SELECT
        *,
        CASE
            WHEN partial_shift      THEN 'partial'
            WHEN NOT holiday_period THEN 'normal'
            WHEN picks < (SELECT AVG(picks) FROM shift_kpis
                          WHERE NOT holiday_period AND NOT partial_shift) THEN 'low'
            ELSE 'peak'
        END                                                          AS shift_type
    FROM shift_kpis
),
median_time AS (
    SELECT
        t.shift_type,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY p.time_per_pick_sec) AS median_sec_per_pick
    FROM analysis.picks AS p
    JOIN typed AS t USING (shift_date)
    GROUP BY t.shift_type
)
SELECT
    t.shift_type,
    COUNT(*)                                                         AS shifts,
    ROUND(AVG(t.picks), 0)                                           AS avg_picks_per_shift,
    ROUND(AVG(t.pickers), 1)                                         AS avg_pickers_per_shift,
    ROUND(AVG(1.0 * t.picks / t.pickers), 0)                         AS avg_picks_per_picker,
    ROUND(SUM(t.timed_picks) / (SUM(t.timed_seconds) / 3600.0), 1)   AS picks_per_hour,
    MAX(m.median_sec_per_pick)                                       AS median_sec_per_pick,
    ROUND(100.0 * SUM(t.occasional_picks) / SUM(t.picks), 1)         AS occasional_share_of_picks_pct
FROM typed AS t
JOIN median_time AS m USING (shift_type)
WHERE t.shift_type <> 'partial'
GROUP BY t.shift_type
ORDER BY CASE t.shift_type WHEN 'low' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END;


/* ----------------------------------------------------------------------------
   5.3 How do pickers and productivity move with volume?
   Across the 19 complete shifts:
     - corr(picks, pickers)        : does staffing follow volume?
     - regr_slope(picks, pickers)  : extra picks handled per extra picker
     - corr(pickers, picks/hour)   : does productivity fall when more pickers work?
   Correlation runs from -1 to 1 (0 = no relationship).
   ---------------------------------------------------------------------------- */

WITH shift_kpis AS (
    SELECT
        shift_date,
        COUNT(*)                                                     AS picks,
        COUNT(DISTINCT picker) FILTER (WHERE is_regular_picker)      AS pickers,
        COUNT(time_per_pick_sec) / (SUM(time_per_pick_sec) / 3600.0)              AS picks_per_hour
    FROM analysis.picks
    WHERE NOT partial_shift
    GROUP BY shift_date
)
SELECT
    COUNT(*)                                                         AS shifts,
    ROUND(CORR(picks, pickers)::numeric, 2)                          AS corr_volume_vs_pickers,
    ROUND(REGR_SLOPE(picks, pickers)::numeric, 0)                    AS extra_picks_per_extra_picker,
    ROUND(CORR(pickers, picks_per_hour)::numeric, 2)                 AS corr_pickers_vs_productivity
FROM shift_kpis;
