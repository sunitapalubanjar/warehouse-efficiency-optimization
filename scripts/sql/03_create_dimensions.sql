-- Drop existing dimension tables (safe for reruns)
DROP TABLE IF EXISTS dw.dim_date CASCADE;
DROP TABLE IF EXISTS dw.dim_picker CASCADE;
DROP TABLE IF EXISTS dw.dim_location CASCADE;

-- 1) dim_date
CREATE TABLE dw.dim_date AS
SELECT DISTINCT
    date AS full_date,
    EXTRACT(YEAR  FROM date)::INT AS year,
    EXTRACT(MONTH FROM date)::INT AS month,
    EXTRACT(WEEK  FROM date)::INT AS week_number,
    weekday_name,
    is_weekend
FROM staging.clean_picking_data
WHERE date IS NOT NULL;

ALTER TABLE dw.dim_date
ADD COLUMN date_key SERIAL PRIMARY KEY;

COMMENT ON TABLE dw.dim_date IS
'Date dimension for time-based analysis (weekday, week, month, year).';


-- 2) dim_picker
CREATE TABLE dw.dim_picker AS
SELECT DISTINCT
    picker
FROM staging.clean_picking_data
WHERE picker IS NOT NULL;

ALTER TABLE dw.dim_picker
ADD COLUMN picker_key SERIAL PRIMARY KEY;

ALTER TABLE dw.dim_picker
ADD CONSTRAINT uq_dim_picker UNIQUE (picker);

COMMENT ON TABLE dw.dim_picker IS
'Picker dimension containing anonymized picker identifiers.';


-- 3) dim_location
CREATE TABLE dw.dim_location AS
SELECT DISTINCT
    location,
    location_row,
    location_id
FROM staging.clean_picking_data
WHERE location IS NOT NULL;

ALTER TABLE dw.dim_location
ADD COLUMN location_key SERIAL PRIMARY KEY;

ALTER TABLE dw.dim_location
ADD CONSTRAINT uq_dim_location UNIQUE (location);

COMMENT ON TABLE dw.dim_location IS
'Location dimension capturing warehouse location attributes (row and location id).';