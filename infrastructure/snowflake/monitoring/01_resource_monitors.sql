-- =============================================================================
-- 01_resource_monitors.sql
-- Resource monitors cap credit consumption per warehouse and send alerts
-- before (and at) the limit to prevent unexpected cost overruns.
--
-- Strategy:
--   • Account-level monitor: hard stop at 90% of monthly budget
--   • Per-warehouse monitors: soft warns at 50%/75%; hard stop at 100%
--   • Notifications sent to the billing-owner email and Slack (via email integration)
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- ACCOUNT-LEVEL MONITOR
-- Acts as a safety net across ALL warehouses.
-- Adjust CREDIT_QUOTA to match your contracted monthly credit allowance.
-- ---------------------------------------------------------------------------

CREATE RESOURCE MONITOR IF NOT EXISTS ACCOUNT_MONTHLY_MONITOR
    WITH
        CREDIT_QUOTA      = 5000            -- Adjust to your monthly contracted credits
        FREQUENCY         = MONTHLY
        START_TIMESTAMP   = IMMEDIATELY
        NOTIFY_USERS      = ('ACCOUNTADMIN_USER', 'billing@mycompany.com')  -- Replace with real users/emails
    TRIGGERS
        ON 50  PERCENT DO NOTIFY           -- Email alert at 50%
        ON 75  PERCENT DO NOTIFY           -- Email alert at 75%
        ON 90  PERCENT DO NOTIFY           -- Email alert at 90%
        ON 100 PERCENT DO SUSPEND_IMMEDIATE; -- Hard stop at 100%

ALTER ACCOUNT SET RESOURCE_MONITOR = ACCOUNT_MONTHLY_MONITOR;

-- ---------------------------------------------------------------------------
-- INGESTION WAREHOUSE MONITOR
-- Ingestion should be predictable; alert quickly on anomalies.
-- ---------------------------------------------------------------------------

CREATE RESOURCE MONITOR IF NOT EXISTS INGESTION_WH_MONITOR
    WITH
        CREDIT_QUOTA    = 200
        FREQUENCY       = MONTHLY
        START_TIMESTAMP = IMMEDIATELY
        NOTIFY_USERS    = ('ACCOUNTADMIN_USER')
    TRIGGERS
        ON 75  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;  -- Suspend (not immediate) to let running loads finish

ALTER WAREHOUSE INGESTION_WH SET RESOURCE_MONITOR = INGESTION_WH_MONITOR;

-- ---------------------------------------------------------------------------
-- TRANSFORM WAREHOUSE MONITOR
-- dbt runs can be expensive; cap at a reasonable monthly allowance.
-- ---------------------------------------------------------------------------

CREATE RESOURCE MONITOR IF NOT EXISTS TRANSFORM_WH_MONITOR
    WITH
        CREDIT_QUOTA    = 500
        FREQUENCY       = MONTHLY
        START_TIMESTAMP = IMMEDIATELY
        NOTIFY_USERS    = ('ACCOUNTADMIN_USER')
    TRIGGERS
        ON 60  PERCENT DO NOTIFY
        ON 80  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE TRANSFORM_WH SET RESOURCE_MONITOR = TRANSFORM_WH_MONITOR;

-- ---------------------------------------------------------------------------
-- ANALYTICS WAREHOUSE MONITOR
-- BI queries can spike; allow higher limit but alert early.
-- ---------------------------------------------------------------------------

CREATE RESOURCE MONITOR IF NOT EXISTS ANALYTICS_WH_MONITOR
    WITH
        CREDIT_QUOTA    = 1000
        FREQUENCY       = MONTHLY
        START_TIMESTAMP = IMMEDIATELY
        NOTIFY_USERS    = ('ACCOUNTADMIN_USER')
    TRIGGERS
        ON 50  PERCENT DO NOTIFY
        ON 75  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE ANALYTICS_WH SET RESOURCE_MONITOR = ANALYTICS_WH_MONITOR;

-- ---------------------------------------------------------------------------
-- DATA SCIENCE WAREHOUSE MONITOR
-- Large queries; tighter cap to prevent runaway jobs.
-- ---------------------------------------------------------------------------

CREATE RESOURCE MONITOR IF NOT EXISTS DATASCIENCE_WH_MONITOR
    WITH
        CREDIT_QUOTA    = 300
        FREQUENCY       = MONTHLY
        START_TIMESTAMP = IMMEDIATELY
        NOTIFY_USERS    = ('ACCOUNTADMIN_USER')
    TRIGGERS
        ON 75  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;  -- DS jobs can be terminated mid-run

ALTER WAREHOUSE DATASCIENCE_WH SET RESOURCE_MONITOR = DATASCIENCE_WH_MONITOR;

-- ---------------------------------------------------------------------------
-- CREDIT USAGE TRACKING VIEW
-- Queryable daily credit consumption by warehouse for showback / chargeback.
-- ---------------------------------------------------------------------------

USE DATABASE MONITORING_DB;
USE SCHEMA COST_MANAGEMENT;

CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDIT_USAGE AS
SELECT
    TO_DATE(start_time) AS usage_date,
    warehouse_name,
    SUM(credits_used)                                    AS credits_used,
    SUM(credits_used_compute)                            AS credits_compute,
    SUM(credits_used_cloud_services)                     AS credits_cloud_services,
    ROUND(SUM(credits_used) * 3.00, 2)                   AS estimated_cost_usd  -- Adjust $/credit for your contract
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1 DESC, credits_used DESC;

CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_MONTHLY_CREDIT_SUMMARY AS
SELECT
    DATE_TRUNC('month', usage_date) AS usage_month,
    warehouse_name,
    SUM(credits_used)               AS monthly_credits,
    ROUND(SUM(credits_used) * 3.00, 2) AS estimated_monthly_cost_usd
FROM MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDIT_USAGE
GROUP BY 1, 2
ORDER BY 1 DESC, monthly_credits DESC;

GRANT SELECT ON VIEW MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDIT_USAGE
    TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.COST_MANAGEMENT.VW_MONTHLY_CREDIT_SUMMARY
    TO ROLE DATA_ENGINEER_ROLE;
