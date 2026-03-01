-- scripts/sql/06_constraints_and_indexes.sql
-- Adds keys, constraints, and indexes to improve integrity + performance for BI queries

-- =========================
-- 1) PRIMARY KEYS (if not already set)
-- =========================
ALTER TABLE dw.dim_date
    ADD CONSTRAINT dim_date_pk PRIMARY KEY (date_key);

ALTER TABLE dw.dim_picker
    ADD CONSTRAINT dim_picker_pk PRIMARY KEY (picker_key);

ALTER TABLE dw.dim_location
    ADD CONSTRAINT dim_location_pk PRIMARY KEY (location_key);

ALTER TABLE dw.fact_picking
    ADD CONSTRAINT fact_picking_pk PRIMARY KEY (picking_id);


-- =========================
-- 2) NOT NULL (core fields)
-- =========================
ALTER TABLE dw.fact_picking
    ALTER COLUMN date_key SET NOT NULL,
    ALTER COLUMN picker_key SET NOT NULL,
    ALTER COLUMN location_key SET NOT NULL,
    ALTER COLUMN duration_sec SET NOT NULL;

-- Optional (keep if volume and wm_vsola are always expected)
-- ALTER TABLE dw.fact_picking
--     ALTER COLUMN volume SET NOT NULL,
--     ALTER COLUMN wm_vsola SET NOT NULL;


-- =========================
-- 3) FOREIGN KEYS (referential integrity)
-- =========================
ALTER TABLE dw.fact_picking
    ADD CONSTRAINT fact_date_fk
    FOREIGN KEY (date_key) REFERENCES dw.dim_date(date_key);

ALTER TABLE dw.fact_picking
    ADD CONSTRAINT fact_picker_fk
    FOREIGN KEY (picker_key) REFERENCES dw.dim_picker(picker_key);

ALTER TABLE dw.fact_picking
    ADD CONSTRAINT fact_location_fk
    FOREIGN KEY (location_key) REFERENCES dw.dim_location(location_key);


-- =========================
-- 4) INDEXES (performance for joins/filters)
-- =========================
-- Indexes on Foreign Keys greatly speed up joins
CREATE INDEX IF NOT EXISTS idx_fact_date_key
    ON dw.fact_picking(date_key);

CREATE INDEX IF NOT EXISTS idx_fact_picker_key
    ON dw.fact_picking(picker_key);

CREATE INDEX IF NOT EXISTS idx_fact_location_key
    ON dw.fact_picking(location_key);


-- =========================
-- 5) QUICK VALIDATION QUERIES
-- =========================
-- Check FK integrity (should return 0 rows)
-- SELECT *
-- FROM dw.fact_picking f
-- LEFT JOIN dw.dim_date d ON f.date_key = d.date_key
-- WHERE d.date_key IS NULL;

-- SELECT *
-- FROM dw.fact_picking f
-- LEFT JOIN dw.dim_picker p ON f.picker_key = p.picker_key
-- WHERE p.picker_key IS NULL;

-- SELECT *
-- FROM dw.fact_picking f
-- LEFT JOIN dw.dim_location l ON f.location_key = l.location_key
-- WHERE l.location_key IS NULL;