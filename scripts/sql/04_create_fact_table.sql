-- Drop existing fact table
DROP TABLE IF EXISTS dw.fact_picking;

-- create fact table
CREATE TABLE dw.fact_picking AS
SELECT
	dp.picker_key,
	dl.location_key,
	dd.date_key,

	--Measures
	s.duration_sec,
	s.volume,
	s.wm_vsola,
	s.start_time,
	s.finish_time,
	s.product_id,
	s.collli_id

FROM staging.clean_picking_data s
JOIN dw.dim_picker dp
	ON s.picker = dp.picker
JOIN dw.dim_location dl
    ON s.location = dl.location
JOIN dw.dim_date dd
    ON s.date = dd.full_date;

-- Add primary key to fact table
ALTER TABLE dw.fact_picking
ADD COLUMN picking_id BIGSERIAL PRIMARY KEY;

COMMENT ON TABLE dw.fact_picking IS
'Fact table containing picking task measures (duration, volume, packages) linked to date, picker, and location dimensions.';