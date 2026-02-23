-- =============================================================================
-- 01_time_travel_config.sql
-- Configures Time Travel retention periods and documents the recovery workflow.
--
-- Snowflake Time Travel allows querying and restoring data as it existed
-- at any point within the retention window (up to 90 days on Enterprise).
-- After the retention window, data moves to Fail-safe (7 days, Snowflake-managed).
--
-- RETENTION STRATEGY:
--   Layer       | Retention  | Justification
--   ------------|------------|----------------------------------------------
--   Bronze (RAW)| 14 days    | Source systems are authoritative; re-ingest if needed
--   Silver      | 30 days    | Business-critical; support end-of-month rollbacks
--   Gold        | 30 days    | BI dashboards should be restorable to any date
--   Monitoring  | 90 days    | Audit logs retained for compliance
--   Transient   | 0 days     | Dev/test tables; save storage
--
-- Run as: SYSADMIN
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- DATABASE-LEVEL TIME TRAVEL (already set in 01_databases.sql; shown here for clarity)
-- ---------------------------------------------------------------------------

-- Bronze
ALTER DATABASE RAW_DB        SET DATA_RETENTION_TIME_IN_DAYS = 14;

-- Silver
ALTER DATABASE FOUNDATION_DB SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- Gold
ALTER DATABASE ANALYTICS_DB  SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- Monitoring / audit
ALTER DATABASE MONITORING_DB SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Non-prod: 0 to save on storage costs
ALTER DATABASE DEV_DB  SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER DATABASE TEST_DB SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- ---------------------------------------------------------------------------
-- TRANSIENT vs PERMANENT TABLES
-- Transient tables have no Fail-safe (saves ~25% storage cost).
-- Use for: landing/staging tables where source can be re-ingested.
-- Use PERMANENT for: silver and gold tables where recovery is business-critical.
-- ---------------------------------------------------------------------------

-- Example: Make landing tables transient (no fail-safe, 0-day time travel)
-- ALTER TABLE RAW_DB.S3_RAW.EVENTS_LANDING SET DATA_RETENTION_TIME_IN_DAYS = 0;
-- Note: to change to TRANSIENT after creation, you must recreate the table.
-- Best practice: declare TRANSIENT at creation time.

-- ---------------------------------------------------------------------------
-- TIME TRAVEL QUERY PATTERNS
-- ---------------------------------------------------------------------------

-- Query a table as it existed 3 days ago
-- SELECT * FROM FOUNDATION_DB.CUSTOMERS.CUSTOMERS AT (OFFSET => -259200); -- -3 days in seconds

-- Query at a specific timestamp
-- SELECT * FROM FOUNDATION_DB.CUSTOMERS.CUSTOMERS
--     AT (TIMESTAMP => '2024-01-15 09:00:00'::TIMESTAMP_NTZ);

-- Query at a specific query ID (before a specific DML ran)
-- SELECT * FROM FOUNDATION_DB.CUSTOMERS.CUSTOMERS
--     BEFORE (STATEMENT => '01abc123-....');

-- Show the query ID of the last DML on a table (for pinpoint recovery)
-- SELECT LAST_QUERY_ID();

-- ---------------------------------------------------------------------------
-- TABLE RECOVERY: UNDROP
-- ---------------------------------------------------------------------------

-- Restore a dropped table (within retention window)
-- UNDROP TABLE FOUNDATION_DB.CUSTOMERS.CUSTOMERS;

-- Restore a dropped schema
-- UNDROP SCHEMA FOUNDATION_DB.CUSTOMERS;

-- Restore a dropped database
-- UNDROP DATABASE ANALYTICS_DB;

-- ---------------------------------------------------------------------------
-- TABLE RECOVERY: CLONE FROM POINT IN TIME
-- Creates a zero-copy clone of the table as it was before an incident.
-- The clone is independent — changes to the original don't affect the clone.
-- ---------------------------------------------------------------------------

-- Create a recovery clone 2 hours before an accidental DELETE
-- CREATE TABLE FOUNDATION_DB.CUSTOMERS.CUSTOMERS_RECOVERY_20240115
--     CLONE FOUNDATION_DB.CUSTOMERS.CUSTOMERS
--     AT (OFFSET => -7200);  -- 2 hours ago

-- Swap the recovery clone into production after validation
-- ALTER TABLE FOUNDATION_DB.CUSTOMERS.CUSTOMERS SWAP WITH
--     FOUNDATION_DB.CUSTOMERS.CUSTOMERS_RECOVERY_20240115;

-- ---------------------------------------------------------------------------
-- ZERO-COPY CLONING FOR DEV/TEST
-- Creates an instantly-ready dev/test environment from production data.
-- Clones share storage with the parent until data diverges.
-- ---------------------------------------------------------------------------

-- Clone the entire ANALYTICS_DB for a developer sprint
-- CREATE DATABASE DEV_DB_SPRINT_42
--     CLONE ANALYTICS_DB;

-- Clone just the silver customers schema for isolated testing
-- CREATE SCHEMA DEV_DB.CUSTOMERS_TEST
--     CLONE FOUNDATION_DB.CUSTOMERS;

-- ---------------------------------------------------------------------------
-- MONITORING VIEW: TABLES NEARING EXPIRY OF TIME TRAVEL
-- ---------------------------------------------------------------------------

USE DATABASE MONITORING_DB;
USE SCHEMA AUDIT;

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_TIME_TRAVEL_STATUS AS
SELECT
    table_catalog,
    table_schema,
    table_name,
    retention_time,
    table_type,
    created,
    last_altered,
    bytes / POWER(1024, 3)              AS size_gb,
    -- Estimated fail-safe cost: size * 7 days * ~$0.0015/TB/hr
    ROUND(bytes / POWER(1024, 4) * 7 * 24 * 0.0015, 4) AS estimated_failsafe_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE deleted IS NULL
  AND table_type = 'BASE TABLE'
ORDER BY table_catalog, table_schema, table_name;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_TIME_TRAVEL_STATUS
    TO ROLE DATA_ENGINEER_ROLE;
