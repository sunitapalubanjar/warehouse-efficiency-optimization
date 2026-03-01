-- Basic validation checks after loading the staging table

-- Row count
SELECT COUNT(*) AS total_rows
FROM staging.clean_picking_data;

-- Quick preview
SELECT *
FROM staging.clean_picking_data
LIMIT 10;

-- Check invalid durations
SELECT COUNT(*) AS invalid_duration_rows
FROM staging.clean_picking_data
WHERE duration_sec IS NULL OR duration_sec <= 0;

-- Check invalid volume
SELECT COUNT(*) AS invalid_volume_rows
FROM staging.clean_picking_data
WHERE volume IS NULL OR volume <= 0;

-- Check date coverage
SELECT MIN(date) AS min_date, MAX(date) AS max_date
FROM staging.clean_picking_data;