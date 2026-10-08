/* ============================================================================
   03_layout_products.sql
   ----------------------------------------------------------------------------
   BQ3  Layout and products: where is picking slow, and why?

   Why  Slotting (where products are stored) is a lever the warehouse controls.

   Hypothesis
        H3: the busiest aisles (01 and 06) are slower per pick, because several
            pickers work there at the same time (congestion).

   Source  analysis.picks (created in 00_setup.sql)

   Important for interpretation
     - Each location holds exactly one product, so a slow aisle may reflect
       the products stored there, not the aisle position. Findings are stated
       as "location/product" effects, and compared within quantity bands.
     - The data has no coordinates or distances: walking distance cannot be
       measured. Aisle changes per colli are used as a proxy for travel.
     - Time per pick = time since the previous pick, so it includes walking to
       this location and picking.

   Queries
     3.1 Three aisle measures: workload, demand intensity, speed
     3.2 Time per pick by aisle within quantity bands
     3.3 Concentration: ABC classes of products, and where the A products are
     3.4 Aisle changes per colli (proxy for travel)
     3.5 Congestion: time per pick by number of pickers in the same aisle (H3)

   Findings: (write after running the queries)
   ============================================================================ */


/* ----------------------------------------------------------------------------
   3.1 Three aisle measures
   - total picks         : workload and possible congestion (shift manager)
   - picks per location  : demand intensity, i.e. where the fast movers are
                           (layout planner); fair because aisles differ in size
   - time per pick       : speed (normal shifts, regular pickers)
   ---------------------------------------------------------------------------- */

SELECT
    aisle,
    COUNT(DISTINCT location)                                         AS locations,
    COUNT(*)                                                         AS picks,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)               AS share_of_picks_pct,
    ROUND(1.0 * COUNT(*) / COUNT(DISTINCT location), 0)              AS picks_per_location,
    RANK() OVER (ORDER BY 1.0 * COUNT(*) / COUNT(DISTINCT location) DESC) AS rank_picks_per_location,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec)
        FILTER (WHERE is_normal_shift)                               AS median_sec_per_pick
FROM analysis.picks
GROUP BY aisle
ORDER BY aisle;


/* ----------------------------------------------------------------------------
   3.2 Time per pick by aisle within quantity bands
   Large-quantity picks take longer, so an aisle with many of them would look
   slow. Comparing each aisle with the median of its quantity band removes that
   effect: index > 1.00 = slower than usual for that band.
   (percentile_cont cannot be used as a window function in PostgreSQL, so the
   band median is calculated in a separate CTE and joined.)
   ---------------------------------------------------------------------------- */

WITH timed AS (
    SELECT aisle, quantity_band, quantity, time_per_pick_sec
    FROM analysis.picks
    WHERE time_per_pick_sec IS NOT NULL
      AND is_normal_shift
),
band_median AS (
    SELECT
        quantity_band,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec) AS band_median_sec
    FROM timed
    GROUP BY quantity_band
),
aisle_band AS (
    SELECT
        aisle,
        quantity_band,
        MIN(quantity)                                                AS band_order,
        COUNT(*)                                                     AS picks,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY time_per_pick_sec) AS aisle_median_sec
    FROM timed
    GROUP BY aisle, quantity_band
)
SELECT
    a.aisle,
    a.quantity_band,
    a.picks,
    a.aisle_median_sec,
    b.band_median_sec,
    ROUND((a.aisle_median_sec / b.band_median_sec)::numeric, 2)      AS speed_index
FROM aisle_band AS a
JOIN band_median AS b USING (quantity_band)
WHERE a.picks >= 100                        -- enough picks for a reliable median
ORDER BY a.aisle, a.band_order;


/* ----------------------------------------------------------------------------
   3.3 Concentration: ABC classes of products
   Products are ranked by picks. A running total (window function) gives the
   share of picks of all products ranked above each product:
     A = products within the first 80% of picks (fast movers)
     B = the next 15%
     C = the last 5% (slow movers)
   The second query shows in which aisles the A and C products are stored.
   ---------------------------------------------------------------------------- */

WITH product_picks AS (
    SELECT product_id, aisle, COUNT(*) AS picks
    FROM analysis.picks
    GROUP BY product_id, aisle
),
classified AS (
    SELECT
        product_id,
        aisle,
        picks,
        CASE
            -- share of picks of all products ranked above this one
            WHEN (SUM(picks) OVER (ORDER BY picks DESC, product_id) - picks)
                 * 100.0 / SUM(picks) OVER () < 80 THEN 'A'
            WHEN (SUM(picks) OVER (ORDER BY picks DESC, product_id) - picks)
                 * 100.0 / SUM(picks) OVER () < 95 THEN 'B'
            ELSE 'C'
        END                                                          AS abc_class
    FROM product_picks
)
SELECT
    abc_class,
    COUNT(*)                                                         AS products,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)               AS share_of_products_pct,
    SUM(picks)                                                       AS picks,
    ROUND(100.0 * SUM(picks) / SUM(SUM(picks)) OVER (), 1)           AS share_of_picks_pct
FROM classified
GROUP BY abc_class
ORDER BY abc_class;

-- Where are the fast movers (A) and slow movers (C) stored?
WITH product_picks AS (
    SELECT product_id, aisle, COUNT(*) AS picks
    FROM analysis.picks
    GROUP BY product_id, aisle
),
classified AS (
    SELECT
        product_id,
        aisle,
        picks,
        CASE
            WHEN (SUM(picks) OVER (ORDER BY picks DESC, product_id) - picks)
                 * 100.0 / SUM(picks) OVER () < 80 THEN 'A'
            WHEN (SUM(picks) OVER (ORDER BY picks DESC, product_id) - picks)
                 * 100.0 / SUM(picks) OVER () < 95 THEN 'B'
            ELSE 'C'
        END                                                          AS abc_class
    FROM product_picks
)
SELECT
    aisle,
    COUNT(*)                                                         AS products,
    COUNT(*) FILTER (WHERE abc_class = 'A')                          AS a_products,
    COUNT(*) FILTER (WHERE abc_class = 'B')                          AS b_products,
    COUNT(*) FILTER (WHERE abc_class = 'C')                          AS c_products,
    ROUND(100.0 * COUNT(*) FILTER (WHERE abc_class = 'A') / COUNT(*), 1) AS a_share_pct
FROM classified
GROUP BY aisle
ORDER BY aisle;


/* ----------------------------------------------------------------------------
   3.4 Aisle changes per colli (proxy for travel)
   LAG gives the aisle of the previous pick in the same colli. A change of
   aisle suggests extra walking. Changes are divided by the number of picks,
   so large and small collis can be compared. The first pick of each colli is
   left out of the time average, because its time includes the changeover from
   the previous colli. Single-line collis are excluded.
   ---------------------------------------------------------------------------- */

WITH sequence AS (
    SELECT
        colli_id,
        aisle,
        time_per_pick_sec,
        LAG(aisle) OVER (PARTITION BY colli_id ORDER BY finish_time) AS previous_aisle
    FROM analysis.picks
    WHERE is_regular_picker
      AND is_normal_shift
      AND NOT is_single_line
),
colli_travel AS (
    SELECT
        colli_id,
        COUNT(*)                                                     AS picks,
        COUNT(*) FILTER (WHERE aisle <> previous_aisle)              AS aisle_changes,
        AVG(time_per_pick_sec) FILTER (WHERE previous_aisle IS NOT NULL) AS avg_sec_per_pick
    FROM sequence
    GROUP BY colli_id
),
quartiles AS (
    SELECT
        *,
        1.0 * aisle_changes / picks                                  AS changes_per_pick,
        NTILE(4) OVER (ORDER BY 1.0 * aisle_changes / picks)         AS travel_quartile
    FROM colli_travel
    WHERE avg_sec_per_pick IS NOT NULL
)
SELECT
    travel_quartile,                         -- 1 = fewest aisle changes per pick
    COUNT(*)                                                         AS collis,
    ROUND(AVG(picks), 1)                                             AS avg_picks_per_colli,
    ROUND(AVG(changes_per_pick)::numeric, 2)                         AS avg_changes_per_pick,
    ROUND(AVG(avg_sec_per_pick)::numeric, 1)                         AS avg_sec_per_pick
FROM quartiles
GROUP BY travel_quartile
ORDER BY travel_quartile;

-- One number for the relationship: correlation between aisle changes per pick
-- and time per pick (0 = no relationship, 1 = perfect positive relationship)
WITH sequence AS (
    SELECT
        colli_id,
        aisle,
        time_per_pick_sec,
        LAG(aisle) OVER (PARTITION BY colli_id ORDER BY finish_time) AS previous_aisle
    FROM analysis.picks
    WHERE is_regular_picker
      AND is_normal_shift
      AND NOT is_single_line
),
colli_travel AS (
    SELECT
        colli_id,
        1.0 * COUNT(*) FILTER (WHERE aisle <> previous_aisle) / COUNT(*) AS changes_per_pick,
        AVG(time_per_pick_sec) FILTER (WHERE previous_aisle IS NOT NULL) AS avg_sec_per_pick
    FROM sequence
    GROUP BY colli_id
)
SELECT ROUND(CORR(changes_per_pick, avg_sec_per_pick)::numeric, 2) AS correlation
FROM colli_travel;


/* ----------------------------------------------------------------------------
   3.5 Congestion: time per pick by number of pickers in the same aisle (H3)
   The shift is cut into 5-minute windows. For every window and aisle, count
   how many different pickers picked there, and link each pick to that count.
   If H3 is true, picks should be slower when more pickers share the aisle.
   - The busy aisles (01 and 06) are shown separately from the others, because
     they hold different products (see 3.3).
   - Picks of 2-12 cases only, so quantity does not distort the comparison.
   - Pickers in the same window were not necessarily in the aisle at the same
     moment, so this is an indication, not proof.
   ---------------------------------------------------------------------------- */

WITH picks_in_window AS (
    SELECT
        *,
        -- 5-minute window number (seconds since 1970 divided by 300)
        FLOOR(EXTRACT(EPOCH FROM finish_time) / 300)                 AS window_5min
    FROM analysis.picks
    WHERE is_regular_picker
      AND is_normal_shift
),
aisle_window AS (
    SELECT
        aisle,
        window_5min,
        COUNT(DISTINCT picker)                                       AS pickers_in_aisle
    FROM picks_in_window
    GROUP BY aisle, window_5min
)
SELECT
    CASE WHEN p.aisle IN (1, 6) THEN 'busy aisles (01, 06)' ELSE 'other aisles' END AS aisle_group,
    CASE
        WHEN w.pickers_in_aisle <= 4  THEN '1-4'
        WHEN w.pickers_in_aisle <= 8  THEN '5-8'
        WHEN w.pickers_in_aisle <= 12 THEN '9-12'
        ELSE '13+'
    END                                                              AS pickers_in_aisle,
    COUNT(*)                                                         AS picks,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY p.time_per_pick_sec) AS median_sec_per_pick,
    ROUND(AVG(p.time_per_pick_sec), 1)                               AS avg_sec_per_pick
FROM picks_in_window AS p
JOIN aisle_window AS w USING (aisle, window_5min)
WHERE p.time_per_pick_sec IS NOT NULL
  AND p.quantity_band IN ('2-5', '6-12')
GROUP BY 1, 2
ORDER BY 1, MIN(w.pickers_in_aisle);
