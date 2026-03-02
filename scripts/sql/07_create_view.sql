-- Create view for top 5 slowest locations per row, row average aand deviation
CREATE OR REPLACE VIEW dw.v_top5_slowest_locations_per_row AS
WITH row_avg AS (
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
        ROUND(AVG(f.duration_sec), 2) AS avg_location_duration_sec,
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
        lp.avg_location_duration_sec,
        ra.avg_row_duration_sec,
        ROUND(lp.avg_location_duration_sec - ra.avg_row_duration_sec, 2) AS deviation_from_row,
        lp.tasks,
        ROW_NUMBER() OVER(
            PARTITION BY lp.location_row
            ORDER BY lp.avg_location_duration_sec DESC
        ) AS rn
    FROM loc_perf lp
    JOIN row_avg ra USING (location_row)
)
SELECT
    location_row,
    location_id,
    avg_location_duration_sec,
    avg_row_duration_sec,
    deviation_from_row,
    tasks
FROM ranked
WHERE rn <= 3
ORDER BY location_row, avg_location_duration_sec DESC;


SELECT * FROM dw.v_top5_slowest_locations_per_row;