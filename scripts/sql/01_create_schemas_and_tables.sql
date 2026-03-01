-- Create schemas for staging and data warehouse layers
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS dw;

COMMENT ON SCHEMA staging IS
'Staging layer for cleaned data loaded from Python before dimensional modeling.';

COMMENT ON SCHEMA dw IS
'Dimensional warehouse layer containing fact and dimension tables for BI reporting.';


-- Staging table for cleaned picking data
DROP TABLE IF EXISTS staging.clean_picking_data;

CREATE TABLE staging.clean_picking_data (
    location      TEXT,
    volume        NUMERIC,
    picker        TEXT,
    calday        TIMESTAMP,
    collli_id     TEXT,
    start_time    TIMESTAMP,
    finish_time   TIMESTAMP,
    wm_vltyp      INT,
    product_id    TEXT,
    duration_sec  INT,
    date          DATE,
    weekday_name  TEXT,
    is_weekend    BOOLEAN,
    location_row  INT,
    location_id   INT,
    wm_vsola      NUMERIC
);

COMMENT ON TABLE staging.clean_picking_data IS
'Cleaned transactional picking dataset prepared in Python and loaded into PostgreSQL.';
