/* ============================================================================
   04_process.sql
   ----------------------------------------------------------------------------
   BQ4  Process: which process issues add avoidable time?

   Why  Process problems are usually the cheapest to fix (replenishment timing,
        location size, order handover), compared with layout or staffing changes.

   Hypothesis
        H4: split lines (continuation lines) are concentrated in a small number
            of products, so fixing their replenishment or location size would
            recover most of the time.

   Source  analysis.picks (created in 00_setup.sql)

   Definitions
     - Split pick       : a pick with a continuation line (has_continuation),
                          i.e. the same product picked again from a second
                          batch or location during the same visit
     - Continuation time: seconds between the first and the last line of a
                          split pick (finish_time - first_finish_time)
     - Changeover       : the first pick of a new colli, whose time includes
                          finishing the previous order and starting the next

   Interpretation
     The data shows WHERE split lines happen and HOW MUCH time they take.
     Possible causes (stock split across batches with different expiry dates,
     a location too small, late replenishment) cannot be confirmed from the data.

   Queries
     4.1 Split rate and continuation time per product
     4.2 How concentrated are split picks? (H4)
     4.3 Do split picks take longer?
     4.4 Changeovers between collis

   Findings: (write after running the queries)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   4.1 Split rate and continuation time per product
   Only products with at least 100 picks, and not new or one-shift products,
   so the split rate is based on enough data.
   ---------------------------------------------------------------------------- */

WITH product_split AS (
    SELECT
        product_id,
        aisle,
        COUNT(*)                                                     AS picks,
        COUNT(*) FILTER (WHERE has_continuation)                     AS split_picks,
        SUM(EXTRACT(EPOCH FROM finish_time - first_finish_time))
            FILTER (WHERE has_continuation)                          AS continuation_sec
    FROM analysis.picks
    WHERE NOT is_new_product
      AND NOT is_one_shift_product
    GROUP BY product_id, aisle
    HAVING COUNT(*) >= 100
)
SELECT
    RANK() OVER (ORDER BY 1.0 * split_picks / picks DESC)            AS rank_split_rate,
    product_id,
    aisle,
    picks,
    split_picks,
    ROUND(100.0 * split_picks / picks, 1)                            AS split_rate_pct,
    ROUND(COALESCE(continuation_sec, 0) / 60.0, 1)                   AS continuation_minutes
FROM product_split
ORDER BY rank_split_rate
LIMIT 15;



------------------

WITH product_split AS (
    SELECT
        product_id,
        aisle,
        COUNT(*)                                                     AS picks,
        COUNT(*) FILTER (WHERE has_continuation)                     AS split_picks,
        SUM(EXTRACT(EPOCH FROM finish_time - first_finish_time))
            FILTER (WHERE has_continuation)                          AS continuation_sec
    FROM analysis.picks
    WHERE NOT is_new_product
      AND NOT is_one_shift_product
    GROUP BY product_id, aisle
    HAVING COUNT(*) >= 100
)
SELECT
    RANK() OVER (ORDER BY 1.0 * split_picks / picks ASC)            AS rank_split_rate,
    product_id,
    aisle,
    picks,
    split_picks,
    ROUND(100.0 * split_picks / picks, 1)                            AS split_rate_pct,
    ROUND(COALESCE(continuation_sec, 0) / 60.0, 1)                   AS continuation_minutes
FROM product_split
ORDER BY rank_split_rate
LIMIT 15;


/* ----------------------------------------------------------------------------
   4.2 How concentrated are split picks? (H4)
   If the top 10 products by split picks account for a large share of all
   split picks and continuation time, the problem can be targeted.
   Continuation time is compared with total working hours (regular pickers).
   ---------------------------------------------------------------------------- */

WITH product_split AS (
    SELECT
        product_id,
        COUNT(*) FILTER (WHERE has_continuation)                     AS split_picks,
        COALESCE(SUM(EXTRACT(EPOCH FROM finish_time - first_finish_time))
            FILTER (WHERE has_continuation), 0)                      AS continuation_sec
    FROM analysis.picks
    GROUP BY product_id
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY split_picks DESC, product_id)    AS split_rank
    FROM product_split
),
totals AS (
    SELECT
        COUNT(*)                                                     AS all_picks,
        SUM(time_per_pick_sec) / 3600.0                              AS working_hours
    FROM analysis.picks
)
SELECT
    (SELECT all_picks FROM totals)                                   AS all_picks,
    SUM(split_picks)                                                 AS split_picks,
    ROUND(100.0 * SUM(split_picks) / (SELECT all_picks FROM totals), 1) AS split_rate_pct,
    COUNT(*) FILTER (WHERE split_picks > 0)                          AS products_with_splits,
    ROUND(100.0 * SUM(split_picks) FILTER (WHERE split_rank <= 10)
          / SUM(split_picks), 1)                                     AS top10_share_of_split_picks_pct,
    ROUND((SUM(continuation_sec) / 3600.0)::numeric, 1)              AS continuation_hours,
    ROUND((100.0 * SUM(continuation_sec) / 3600.0
          / (SELECT working_hours FROM totals))::numeric, 1)         AS share_of_working_hours_pct,
    ROUND((100.0 * SUM(continuation_sec) FILTER (WHERE split_rank <= 10)
          / SUM(continuation_sec))::numeric, 1)                      AS top10_share_of_continuation_time_pct
FROM ranked;


/* ----------------------------------------------------------------------------
   4.3 Do split picks take longer?
   Compared within the same quantity band, because split picks tend to have
   larger quantities. (A split pick always has at least 2 cases, so the
   1-case band has no split picks.)
   ---------------------------------------------------------------------------- */

SELECT
    quantity_band,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)
        FILTER (WHERE NOT has_continuation)                          AS normal_median_sec,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)
        FILTER (WHERE has_continuation)                              AS split_median_sec,
    COUNT(time_per_pick_sec) FILTER (WHERE NOT has_continuation)     AS normal_picks,
    COUNT(time_per_pick_sec) FILTER (WHERE has_continuation)         AS split_picks
FROM analysis.picks
WHERE time_per_pick_sec IS NOT NULL
  AND is_normal_shift
GROUP BY quantity_band
ORDER BY MIN(quantity);


/* ----------------------------------------------------------------------------
   4.4 Changeovers between collis
   LAG gives the colli of the picker's previous pick in the same shift. If it
   is a different colli, this pick is the first of a new order and its time
   includes the changeover (finishing one order, starting the next).
   ---------------------------------------------------------------------------- */

WITH sequence AS (
    SELECT
        colli_id,
        time_per_pick_sec,
        LAG(colli_id) OVER (PARTITION BY picker, shift_date ORDER BY finish_time) AS previous_colli
    FROM analysis.picks
    WHERE is_regular_picker
      AND is_normal_shift
)
SELECT
    CASE WHEN colli_id = previous_colli THEN 'within colli' ELSE 'new colli (changeover)' END AS pick_type,
    COUNT(*)                                                         AS picks,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)   AS median_sec,
    ROUND(AVG(time_per_pick_sec), 1)                                 AS avg_sec,
    ROUND(SUM(time_per_pick_sec) / 3600.0, 1)                        AS hours,
    ROUND(100.0 * SUM(time_per_pick_sec) / SUM(SUM(time_per_pick_sec)) OVER (), 1) AS share_of_time_pct
FROM sequence
WHERE time_per_pick_sec IS NOT NULL
  AND previous_colli IS NOT NULL
GROUP BY 1
ORDER BY 1 DESC;
