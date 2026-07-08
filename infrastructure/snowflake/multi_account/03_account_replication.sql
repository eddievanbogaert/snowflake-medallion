-- =============================================================================
-- multi_account/03_account_replication.sql
-- Cross-region and cross-account replication for HA/DR and audit isolation.
--
-- USE CASES
-- ---------
--   1. Primary / DR failover — replicate PROD to a secondary region so that
--      if AWS US-East-1 has an outage, you can fail over to AWS US-West-2.
--   2. Audit log isolation — replicate MONITORING_DB from PROD to a locked-down
--      governance account, so audit logs can't be tampered with by the PROD admin.
--   3. Cross-region data residency — replicate a subset of data to an EU account
--      to meet GDPR data residency requirements.
--
-- REPLICATION GROUPS vs DATABASE REPLICATION
-- -------------------------------------------
-- Snowflake offers two replication models:
--
--   Database Replication (older, simpler):
--     Replicates a single database independently.
--     Failover is per-database; no account-level objects replicated.
--
--   Replication Groups / Failover Groups (recommended):
--     Replicates multiple databases + account-level objects (roles, users,
--     network policies, warehouses) as a consistent unit.
--     FAILOVER GROUP supports one-command role-swap for DR.
--     Requires Snowflake Business Critical edition.
--
-- This template uses Failover Groups (the recommended approach).
--
-- Run as: ACCOUNTADMIN (on both primary and secondary accounts)
--
-- GOVERNMENT / PUBLIC SECTOR NOTES
-- ---------------------------------
-- • Failover Groups require Snowflake Business Critical edition. FedRAMP High
--   environments (snowflakecomputing.mil) also support this feature, but
--   cross-region failover targets must themselves be within the authorized
--   FedRAMP boundary (e.g., only replicate to another FedRAMP-authorized region).
-- • For DoD IL5 workloads, confirm the secondary region's impact-level
--   authorization before enabling cross-region replication.
-- • Some government contracts prohibit replication outside a specific cloud
--   boundary entirely — verify before configuring cross-account replication.
-- • Commercial cloud Snowflake accounts CANNOT be used as replication targets
--   for FedRAMP-authorized accounts; keep both primary and DR within the
--   same authorized boundary.
-- =============================================================================

-- =============================================================================
-- PART A: PRIMARY ACCOUNT SETUP
-- Run on: PROD account (e.g., ACME-PROD)
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- ENABLE REPLICATION TO SECONDARY ACCOUNTS
-- Allows the secondary account to pull replicated data.
-- Replace <ORG>.<SECONDARY_ACCOUNT> with your actual account identifiers.
-- ---------------------------------------------------------------------------

-- Enable replication for specific databases on the primary account.
-- (Commented out because the identifiers are placeholders — replace
--  <ORG>.<ACME_PROD_DR> with your real org.account identifier, then run.)
-- Note: this legacy per-database step is only needed for standalone database
-- replication; the failover group below manages its own database list.
-- ALTER DATABASE RAW_DB        ENABLE REPLICATION TO ACCOUNTS <ORG>.<ACME_PROD_DR>;
-- ALTER DATABASE FOUNDATION_DB ENABLE REPLICATION TO ACCOUNTS <ORG>.<ACME_PROD_DR>;
-- ALTER DATABASE ANALYTICS_DB  ENABLE REPLICATION TO ACCOUNTS <ORG>.<ACME_PROD_DR>;
-- ALTER DATABASE MONITORING_DB ENABLE REPLICATION TO ACCOUNTS <ORG>.<ACME_PROD_DR>;

-- ---------------------------------------------------------------------------
-- CREATE FAILOVER GROUP (recommended for DR)
-- A failover group replicates databases + account-level objects atomically.
-- ---------------------------------------------------------------------------

-- NOTE: COMMENT is NOT a supported parameter for CREATE FAILOVER GROUP.
-- Valid OBJECT_TYPES: ACCOUNT PARAMETERS, DATABASES, EXTERNAL VOLUMES,
--   INTEGRATIONS, LISTINGS, NETWORK POLICIES, PROFILES, RESOURCE MONITORS,
--   ROLES, SHARES, USERS, WAREHOUSES
-- (Commented out — replace <ORG>.<ACME_PROD_DR> with your real
--  org.account identifier, then run.)
-- CREATE FAILOVER GROUP IF NOT EXISTS PROD_FAILOVER_GROUP
--     OBJECT_TYPES = DATABASES,
--                    USERS,
--                    ROLES,
--                    WAREHOUSES,
--                    RESOURCE MONITORS,
--                    NETWORK POLICIES
--     ALLOWED_DATABASES = RAW_DB, FOUNDATION_DB, ANALYTICS_DB, MONITORING_DB
--     ALLOWED_ACCOUNTS  = <ORG>.<ACME_PROD_DR>       -- secondary (DR) account
--     REPLICATION_SCHEDULE = '10 MINUTES';            -- RPO = 10 minutes

-- ---------------------------------------------------------------------------
-- REFRESH ON-DEMAND (manual trigger for testing or emergency cutover)
-- ---------------------------------------------------------------------------

-- ALTER FAILOVER GROUP PROD_FAILOVER_GROUP REFRESH;

-- =============================================================================
-- PART B: SECONDARY (DR) ACCOUNT SETUP
-- Run on: DR account (e.g., ACME-PROD-DR) — different account, same SQL client
-- =============================================================================

-- Connect to the DR account, then run:

-- USE ROLE ACCOUNTADMIN;

-- Create the secondary failover group — mirrors the primary
-- CREATE FAILOVER GROUP PROD_FAILOVER_GROUP
--     AS REPLICA OF <ORG>.<ACME-PROD>.PROD_FAILOVER_GROUP;

-- ---------------------------------------------------------------------------
-- FAILOVER PROCEDURE  (break-glass for DR)
-- Promotes the secondary to primary. Run on the SECONDARY account.
-- The old primary becomes a secondary automatically.
-- ---------------------------------------------------------------------------

-- -- 1. Verify replication lag before failing over
-- SELECT phase_name, start_time, end_time
-- FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('PROD_FAILOVER_GROUP'))
-- ORDER BY start_time DESC;

-- -- 2. Initiate failover (makes this account the new primary)
-- ALTER FAILOVER GROUP PROD_FAILOVER_GROUP PRIMARY;

-- -- 3. Update DNS / connection strings to point to the new primary account
-- --    (this step is outside Snowflake — update your dbt profiles, BI tool
-- --    data sources, and Fivetran connector configuration)

-- -- 4. After the old primary account recovers:
-- --    Re-add it as a secondary by running CREATE FAILOVER GROUP ... AS REPLICA OF ...
-- --    from the original primary account.

-- =============================================================================
-- PART C: AUDIT LOG REPLICATION TO GOVERNANCE ACCOUNT
-- Replicates MONITORING_DB from PROD to a read-only governance account.
-- The governance account has no ACCOUNTADMIN; audit logs are tamper-evident.
-- =============================================================================

-- Run on PROD account:
-- ALTER DATABASE MONITORING_DB ENABLE REPLICATION TO ACCOUNTS <ORG>.<ACME-GOVERNANCE>;

-- Run on GOVERNANCE account:
-- CREATE DATABASE MONITORING_DB_PROD
--     AS REPLICA OF <ORG>.<ACME-PROD>.MONITORING_DB;
-- ALTER DATABASE MONITORING_DB_PROD REFRESH;   -- initial sync
--
-- Standalone database replicas have no built-in schedule — refresh them with
-- a task on the governance account (or move the database into a replication
-- group, which has its own REPLICATION_SCHEDULE):
-- CREATE TASK IF NOT EXISTS REFRESH_MONITORING_DB_PROD
--     WAREHOUSE = ADMIN_WH
--     SCHEDULE  = '60 MINUTES'
-- AS
--     ALTER DATABASE MONITORING_DB_PROD REFRESH;
-- ALTER TASK REFRESH_MONITORING_DB_PROD RESUME;

-- =============================================================================
-- MONITORING: REPLICATION LAG AND HEALTH
-- Run these on the SECONDARY account AFTER the failover group exists.
-- REPLICATION_GROUP_REFRESH_HISTORY returns: PHASE_NAME, START_TIME, END_TIME,
-- JOB_UUID, TOTAL_BYTES (JSON), OBJECT_COUNT (JSON), COMMITTED_OBJECT_COUNT,
-- PRIMARY_SNAPSHOT_TIMESTAMP, ERROR (JSON).
-- =============================================================================

-- Check refresh phases for the failover group (most recent first):
-- SELECT phase_name, start_time, end_time,
--        DATEDIFF('minute', start_time, end_time) AS duration_minutes,
--        error
-- FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('PROD_FAILOVER_GROUP'))
-- ORDER BY start_time DESC;

-- Check replication lag for individual databases (legacy database replication):
-- SELECT *
-- FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.DATABASE_REFRESH_HISTORY())
-- ORDER BY start_time DESC
-- LIMIT 20;

-- Queryable health view (create after the failover group exists — the view
-- references the group by name and will fail validation without it)
CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_REPLICATION_HEALTH AS
SELECT
    phase_name,
    start_time,
    end_time,
    DATEDIFF('minute', start_time, end_time)  AS duration_minutes,
    committed_object_count,
    primary_snapshot_timestamp,
    error
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('PROD_FAILOVER_GROUP'))
ORDER BY start_time DESC;

GRANT SELECT ON VIEW MONITORING_DB.COST_MANAGEMENT.VW_REPLICATION_HEALTH
    TO ROLE DATA_ENGINEER_ROLE;

-- Alert if no refresh has COMPLETED in the last 20 minutes (RPO breach risk).
-- Runs on the secondary account, where the refresh history is recorded.
CREATE ALERT IF NOT EXISTS ALERT_REPLICATION_LAG
    WAREHOUSE  = ADMIN_WH
    SCHEDULE   = '10 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM (
            SELECT MAX(end_time) AS last_completed
            FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('PROD_FAILOVER_GROUP'))
            WHERE phase_name = 'COMPLETED'
        )
        WHERE last_completed IS NULL
           OR last_completed < DATEADD('minute', -20, CURRENT_TIMESTAMP())
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: Snowflake Replication Group Lag or Failure',
            'The PROD_FAILOVER_GROUP replication has not completed successfully '
            || 'in over 20 minutes. RPO may be at risk. Check VW_REPLICATION_HEALTH '
            || 'and Snowflake status page.'
        );

ALTER ALERT ALERT_REPLICATION_LAG RESUME;
