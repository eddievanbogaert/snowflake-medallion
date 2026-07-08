-- =============================================================================
-- 02_replication.sql
-- Configures cross-region / cross-cloud replication for Business Continuity.
--
-- Architecture:
--   PRIMARY: us-east-1 (AWS)    → all databases
--   SECONDARY (DR): eu-west-1 (AWS) → ANALYTICS_DB + FOUNDATION_DB (read replica)
--
-- Replication types:
--   1. Database Replication: point-in-time snapshot replication of specific databases
--   2. Failover Groups (Business Critical): replicate multiple databases as a group
--      with automated failover capability.
--
-- IMPORTANT: Replication requires a secondary Snowflake account in the target region.
-- Both accounts must be in the same organisation.
-- Replication incurs data transfer and compute costs in the target account.
--
-- Run as: ACCOUNTADMIN (primary account)
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- STEP 1: ENABLE REPLICATION ON PRIMARY ACCOUNT (run on PRIMARY account)
-- ---------------------------------------------------------------------------

-- Enable the primary ANALYTICS_DB for replication to the DR account
ALTER DATABASE ANALYTICS_DB
    ENABLE REPLICATION TO ACCOUNTS myorg.dr_account_eu;

ALTER DATABASE FOUNDATION_DB
    ENABLE REPLICATION TO ACCOUNTS myorg.dr_account_eu;

-- (Optional) Include MONITORING_DB for audit trail replication
-- ALTER DATABASE MONITORING_DB
--     ENABLE REPLICATION TO ACCOUNTS myorg.dr_account_eu;

-- ---------------------------------------------------------------------------
-- STEP 2: CREATE SECONDARY DATABASES (run on SECONDARY/DR account)
-- ---------------------------------------------------------------------------

-- Connect to the DR account and run:
-- CREATE DATABASE ANALYTICS_DB
--     AS REPLICA OF myorg.primary_account.ANALYTICS_DB
--     DATA_RETENTION_TIME_IN_DAYS = 1  -- Secondary doesn't need long retention
--     COMMENT = 'DR replica of production ANALYTICS_DB. Read-only.';
--
-- CREATE DATABASE FOUNDATION_DB
--     AS REPLICA OF myorg.primary_account.FOUNDATION_DB
--     DATA_RETENTION_TIME_IN_DAYS = 1
--     COMMENT = 'DR replica of production FOUNDATION_DB. Read-only.';

-- ---------------------------------------------------------------------------
-- STEP 3: SCHEDULE REPLICATION REFRESH (run on SECONDARY account)
-- Refresh can be triggered manually or scheduled via a task.
-- ---------------------------------------------------------------------------

-- Manual refresh (on demand)
-- ALTER DATABASE ANALYTICS_DB REFRESH;

-- Scheduled task for automated refresh (every 4 hours)
-- CREATE TASK IF NOT EXISTS REPLICATE_ANALYTICS_DB
--     WAREHOUSE   = ADMIN_WH
--     SCHEDULE    = '240 MINUTES'
-- AS
--     ALTER DATABASE ANALYTICS_DB REFRESH;
--
-- CREATE TASK IF NOT EXISTS REPLICATE_FOUNDATION_DB
--     WAREHOUSE   = ADMIN_WH
--     SCHEDULE    = '240 MINUTES'
--     AFTER REPLICATE_ANALYTICS_DB  -- Chain tasks
-- AS
--     ALTER DATABASE FOUNDATION_DB REFRESH;
--
-- ALTER TASK REPLICATE_ANALYTICS_DB RESUME;
-- ALTER TASK REPLICATE_FOUNDATION_DB RESUME;

-- ---------------------------------------------------------------------------
-- FAILOVER GROUPS (Business Critical only)
-- Failover groups replicate multiple databases atomically and allow
-- automated promotion of the secondary to primary in a DR event.
-- ---------------------------------------------------------------------------

-- Create a failover group on the PRIMARY account
-- CREATE FAILOVER GROUP PROD_FAILOVER_GROUP
--     OBJECT_TYPES = DATABASES, INTEGRATIONS, NETWORK POLICIES, RESOURCE MONITORS, ROLES, USERS
--     ALLOWED_DATABASES = ANALYTICS_DB, FOUNDATION_DB, MONITORING_DB
--     ALLOWED_INTEGRATION_TYPES = SECURITY INTEGRATIONS, API INTEGRATIONS
--     ALLOWED_ACCOUNTS = myorg.dr_account_eu
--     REPLICATION_SCHEDULE = '60 MINUTES';

-- Create a secondary failover group (run on DR account)
-- CREATE FAILOVER GROUP PROD_FAILOVER_GROUP
--     AS REPLICA OF myorg.primary_account.PROD_FAILOVER_GROUP;

-- In a DR event: promote secondary to primary (run on DR account)
-- ALTER FAILOVER GROUP PROD_FAILOVER_GROUP PRIMARY;

-- ---------------------------------------------------------------------------
-- REPLICATION MONITORING
-- ---------------------------------------------------------------------------

-- Replication status (primary/secondary, allowed target accounts) comes from
-- SHOW REPLICATION DATABASES. SHOW output cannot be wrapped in a view —
-- ACCOUNT_USAGE.DATABASES does not carry replication columns — so run ad hoc:
--
-- SHOW REPLICATION DATABASES;
-- SELECT "name", "is_primary", "primary",
--        "replication_allowed_to_accounts", "failover_allowed_to_accounts"
-- FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Replication cost and volume per database (viewable — ACCOUNT_USAGE):
CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_REPLICATION_COST AS
SELECT
    database_name,
    TO_DATE(start_time)                       AS usage_date,
    SUM(credits_used)                         AS credits_used,
    SUM(bytes_transferred) / POWER(1024, 3)   AS gb_transferred
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY database_name, TO_DATE(start_time)
ORDER BY usage_date DESC, credits_used DESC;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_REPLICATION_COST
    TO ROLE DATA_ENGINEER_ROLE;

-- View replication lag (run on secondary account)
-- SELECT database_name, phase_name, result, start_time, end_time
-- FROM TABLE(INFORMATION_SCHEMA.DATABASE_REFRESH_HISTORY('ANALYTICS_DB'))
-- ORDER BY start_time DESC
-- LIMIT 20;
