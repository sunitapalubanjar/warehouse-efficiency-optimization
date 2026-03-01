--============================
--1) Overall KPIs
--===========================
-- Average picking duration(seconds)
SELECT ROUND(AVG(duration_sec), 2) AS avg_picking_duration_sec
FROM dw.fact_picking;

-- Total tasks
SELECT COUNT(*) AS total_picking_tasks
FROM dw.fact_picking;

-- ============================================================
-- 2) Weekday Performance (Weekend vs Weekday)
-- ============================================================

-- Avg duration by weekday
SELECT 
	d.weekday_name,
	ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
	COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_date d
	USING (date_key)
GROUP BY d.weekday_name
ORDER BY avg_duration_sec;

-- Weekend vs Weekday comparison
SELECT
    d.is_weekend,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_date d ON f.date_key = d.date_key
GROUP BY d.is_weekend
ORDER BY d.is_weekend DESC;

-- ============================================================
-- 3) Picker Performance (Efficiency Ranking)
-- ============================================================

-- Avg duration by picker (minimum task threshold)
SELECT
    p.picker,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_picker p ON f.picker_key = p.picker_key
GROUP BY p.picker
HAVING COUNT(*) >= 100
ORDER BY avg_duration_sec DESC;


-- Average duration by picker with less than 100 tasks

SELECT
    p.picker,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_picker p ON f.picker_key = p.picker_key
GROUP BY p.picker
HAVING COUNT(*) <= 100
ORDER BY avg_duration_sec DESC;



-- Top 10 fastest pickers (by avg duration)
SELECT
    p.picker,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_picker p ON f.picker_key = p.picker_key
GROUP BY p.picker
HAVING COUNT(*) >= 100
ORDER BY avg_duration_sec ASC
LIMIT 10;

-- Top 10 slowest pickers (by avg duration)
SELECT
    p.picker,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_picker p ON f.picker_key = p.picker_key
GROUP BY p.picker
HAVING COUNT(*) >= 100
ORDER BY avg_duration_sec DESC
LIMIT 10;

-- ============================================================
-- 4) Warehouse Layout Performance (Hotspots)
-- ============================================================

-- Avg duration by warehouse row
SELECT
    l.location_row,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_location l ON f.location_key = l.location_key
GROUP BY l.location_row
ORDER BY avg_duration_sec DESC;

-- Top 15 slowest locations
SELECT
    l.location,
    l.location_row,
    l.location_id,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_location l ON f.location_key = l.location_key
GROUP BY l.location, l.location_row, l.location_id
HAVING COUNT(*) >= 50
ORDER BY avg_duration_sec DESC
LIMIT 15;



-- Top 5 slowest locations within each row
-- + overall row average
-- + deviation from row average

WITH row_avg AS (
    -- True overall row average based on ALL tasks
    SELECT
        l.location_row,
        ROUND(AVG(f.duration_sec), 2) AS avg_row_duration_sec
    FROM dw.fact_picking f
    JOIN dw.dim_location l USING (location_key)
    GROUP BY l.location_row
),

loc_perf AS (
    SELECT 
        l.location_row,
        l.location_id,
        ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
        COUNT(*) AS tasks
    FROM dw.fact_picking f
    JOIN dw.dim_location l USING (location_key)
    GROUP BY l.location_row, l.location_id
    HAVING COUNT(*) >= 50
),

ranked AS (
    SELECT 
        lp.location_row,
        lp.location_id,
        lp.avg_duration_sec,
        ra.avg_row_duration_sec,
        (lp.avg_duration_sec - ra.avg_row_duration_sec) 
            AS deviation_from_row,
        lp.tasks,
        ROW_NUMBER() OVER(
            PARTITION BY lp.location_row
            ORDER BY lp.avg_duration_sec DESC
        ) AS rn
    FROM loc_perf lp
    JOIN row_avg ra 
        USING (location_row)
)

SELECT
    location_row,
    location_id,
    avg_duration_sec,
    avg_row_duration_sec,
    deviation_from_row,
    tasks
FROM ranked
WHERE rn <= 5
ORDER BY location_row, avg_duration_sec DESC;


-- ============================================================
-- 5) Volume Impact (Operational Complexity)
-- ============================================================

-- Avg duration by volume category
SELECT
    CASE
        WHEN volume < 0.01 THEN 'Low'
        WHEN volume < 0.05 THEN 'Medium'
        ELSE 'High'
    END AS volume_category,
    ROUND(AVG(duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking
GROUP BY volume_category
ORDER BY avg_duration_sec DESC;

-- Correlation-style view: volume buckets
SELECT
    WIDTH_BUCKET(volume, 0, 0.5, 10) AS volume_bucket,
    ROUND(AVG(duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking
WHERE volume IS NOT NULL
GROUP BY volume_bucket
ORDER BY volume_bucket;

-- ============================================================
-- 7) Time Trend (Daily)
-- ============================================================

-- Avg duration per day
SELECT
    d.full_date,
    ROUND(AVG(f.duration_sec), 2) AS avg_duration_sec,
    COUNT(*) AS tasks
FROM dw.fact_picking f
JOIN dw.dim_date d ON f.date_key = d.date_key
GROUP BY d.full_date
ORDER BY d.full_date;