-- ==========================================
-- 1. DDL: RAW, STAGING & COUNTRY TABLES
-- ==========================================
CREATE OR REPLACE TABLE raw_members (
    raw_line VARCHAR,
    file_name VARCHAR,
    load_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE raw_redemptions (
    payload VARIANT,
    load_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE quarantine_members (
    raw_line VARCHAR,
    reason VARCHAR,
    load_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE stg_members (
    member_id VARCHAR(18) NOT NULL,
    member_name VARCHAR(255) NOT NULL,
    enrollment_date DATE NOT NULL,
    last_flight_date DATE,
    tier_code VARCHAR(5),
    agent_name VARCHAR(255),
    state VARCHAR(5),
    country VARCHAR(5) NOT NULL,
    dob DATE,
    is_active CHAR(1),
    age NUMBER(3,0),
    stale_member BOOLEAN,
    load_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (country, member_id);

-- Country target tables (clustered by member_id for fast billion-row MERGEs)
CREATE OR REPLACE TABLE Table_USA (
    member_id VARCHAR(18) PRIMARY KEY,
    member_name VARCHAR(255) NOT NULL,
    enrollment_date DATE NOT NULL,
    last_flight_date DATE,
    tier_code VARCHAR(5),
    agent_name VARCHAR(255),
    state VARCHAR(5),
    country VARCHAR(5) NOT NULL,
    dob DATE,
    is_active CHAR(1),
    age NUMBER(3,0),
    stale_member BOOLEAN
) CLUSTER BY (member_id);

CREATE OR REPLACE TABLE Table_India       LIKE Table_USA;
CREATE OR REPLACE TABLE Table_Australia   LIKE Table_USA;
CREATE OR REPLACE TABLE Table_Canada      LIKE Table_USA;
CREATE OR REPLACE TABLE Table_Philippines LIKE Table_USA;

-- ==========================================
-- 2. LOAD STAGING + DERIVED COLUMNS (Age, Stale_Member)
-- ==========================================
INSERT INTO stg_members (
    member_id, member_name, enrollment_date, last_flight_date,
    tier_code, agent_name, state, country, dob, is_active, age, stale_member
)
WITH parsed AS (
    SELECT SPLIT(TRIM(raw_line, ' |'), '|') AS c
    FROM raw_members
    WHERE UPPER(TRIM(SPLIT_PART(TRIM(raw_line, ' |'), '|', 1))) = 'D'
)
SELECT
    TRIM(c[2]::VARCHAR)                                           AS member_id,
    TRIM(c[1]::VARCHAR)                                           AS member_name,
    TRY_TO_DATE(TRIM(c[3]::VARCHAR), 'YYYYMMDD')                  AS enrollment_date,
    TRY_TO_DATE(TRIM(c[4]::VARCHAR), 'YYYYMMDD')                  AS last_flight_date,
    UPPER(TRIM(c[5]::VARCHAR))                                    AS tier_code,
    TRIM(c[6]::VARCHAR)                                           AS agent_name,
    UPPER(TRIM(c[7]::VARCHAR))                                    AS state,
    CASE UPPER(TRIM(c[8]::VARCHAR))
        WHEN 'AU' THEN 'AUS'
        WHEN 'PHIL' THEN 'PHL'
        ELSE UPPER(TRIM(c[8]::VARCHAR))
    END                                                           AS country,
    TRY_TO_DATE(LPAD(TRIM(c[9]::VARCHAR), 8, '0'), 'DDMMYYYY')    AS dob,
    UPPER(TRIM(c[10]::VARCHAR))                                   AS is_active,
    DATEDIFF('year', dob, CURRENT_DATE())                         AS age,
    IFF(last_flight_date IS NULL OR DATEDIFF('day', last_flight_date, CURRENT_DATE()) > 90, TRUE, FALSE) AS stale_member
FROM parsed
WHERE ARRAY_SIZE(c) = 11
  AND member_id <> '' AND member_name <> '' AND enrollment_date IS NOT NULL;

-- ==========================================
-- 3. SPLIT BY COUNTRY ("LATEST RECORD WINS")
-- ==========================================
CREATE OR REPLACE TEMP TABLE latest_members AS
SELECT * FROM stg_members
QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY load_ts DESC) = 1;

-- Remove relocated members from old country tables (example shown for USA & India; repeat per country)
DELETE FROM Table_USA   USING latest_members s WHERE Table_USA.member_id   = s.member_id AND s.country <> 'USA';
DELETE FROM Table_India USING latest_members s WHERE Table_India.member_id = s.member_id AND s.country <> 'IND';

-- Upsert into target country table (repeat pattern for each country)
MERGE INTO Table_USA t
USING (SELECT * FROM latest_members WHERE country = 'USA') s
ON t.member_id = s.member_id
WHEN MATCHED THEN UPDATE SET
    t.member_name = s.member_name, t.last_flight_date = s.last_flight_date,
    t.tier_code = s.tier_code, t.state = s.state, t.age = s.age, t.stale_member = s.stale_member
WHEN NOT MATCHED THEN INSERT (
    member_id, member_name, enrollment_date, last_flight_date,
    tier_code, agent_name, state, country, dob, is_active, age, stale_member
) VALUES (
    s.member_id, s.member_name, s.enrollment_date, s.last_flight_date,
    s.tier_code, s.agent_name, s.state, s.country, s.dob, s.is_active, s.age, s.stale_member
);

-- ==========================================
-- 4. FLATTEN JSON REDEMPTIONS & JOIN BACK
-- ==========================================
CREATE OR REPLACE TABLE fact_redemptions (
    txn_id VARCHAR PRIMARY KEY,
    member_id VARCHAR(18) NOT NULL,
    feed_date DATE,
    txn_date DATE,
    partner VARCHAR,
    miles_redeemed NUMBER,
    status VARCHAR
) CLUSTER BY (member_id, txn_date);

MERGE INTO fact_redemptions t
USING (
    SELECT
        r.value:txn_id::VARCHAR                          AS txn_id,
        TRIM(raw.payload:"member id"::VARCHAR)           AS member_id,
        TRY_TO_DATE(raw.payload:feed_date::VARCHAR, 'YYYYMMDD') AS feed_date,
        TRY_TO_DATE(r.value:txn_date::VARCHAR, 'YYYYMMDD')      AS txn_date,
        r.value:partner::VARCHAR                         AS partner,
        r.value:miles_redeemed::NUMBER                   AS miles_redeemed,
        UPPER(r.value:status::VARCHAR)                   AS status
    FROM raw_redemptions raw,
         LATERAL FLATTEN(input => raw.payload:redemptions) r
) s
ON t.txn_id = s.txn_id
WHEN MATCHED THEN UPDATE SET t.status = s.status, t.feed_date = s.feed_date
WHEN NOT MATCHED THEN INSERT VALUES (s.txn_id, s.member_id, s.feed_date, s.txn_date, s.partner, s.miles_redeemed, s.status);

-- Unified view across country tables to join redemptions back to profiles
CREATE OR REPLACE VIEW vw_all_members AS
SELECT * FROM Table_USA
UNION ALL SELECT * FROM Table_India
UNION ALL SELECT * FROM Table_Australia
UNION ALL SELECT * FROM Table_Canada
UNION ALL SELECT * FROM Table_Philippines;

SELECT f.*, m.member_name, m.country, m.tier_code
FROM fact_redemptions f
LEFT JOIN vw_all_members m ON f.member_id = m.member_id;

-- ==========================================
-- 5. DATA VALIDATION CHECKS
-- ==========================================
-- A. Quarantine malformed rows (catches missing pipes like Ravi's row, missing mandatory fields, bad dates)
INSERT INTO quarantine_members (raw_line, reason)
SELECT raw_line, 'MALFORMED_OR_MISSING_MANDATORY'
FROM raw_members
WHERE UPPER(TRIM(SPLIT_PART(TRIM(raw_line, ' |'), '|', 1))) = 'D'
  AND (
      ARRAY_SIZE(SPLIT(TRIM(raw_line, ' |'), '|')) <> 11
      OR TRIM(SPLIT(TRIM(raw_line, ' |'), '|')[2]::VARCHAR) = ''
      OR TRY_TO_DATE(TRIM(SPLIT(TRIM(raw_line, ' |'), '|')[3]::VARCHAR), 'YYYYMMDD') IS NULL
  );

-- B. Key-column uniqueness across all country tables (must return 0 rows)
SELECT member_id, COUNT(*) FROM vw_all_members GROUP BY member_id HAVING COUNT(*) > 1;

-- C. Logical checks (must return 0 rows)
SELECT member_id FROM stg_members WHERE last_flight_date < enrollment_date OR age < 0 OR age > 120;