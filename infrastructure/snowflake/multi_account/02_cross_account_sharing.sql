-- =============================================================================
-- multi_account/02_cross_account_sharing.sql
-- Secure Data Sharing between Snowflake accounts within the same organisation.
--
-- USE CASES
-- ---------
--   1. Publishing curated gold-layer data products from PROD to a downstream
--      analytics account (no data movement, near-zero cost to consumer).
--   2. Sharing reference / lookup data across BU accounts (e.g. a shared
--      product catalogue maintained centrally).
--   3. Distributing platform-wide monitoring data (cost, quality alerts) to
--      a centralised governance account.
--   4. Snowflake Marketplace publishing (if data products are monetized).
--
-- HOW IT WORKS
-- ------------
-- Snowflake Data Sharing creates a read-only "share" object on the provider
-- account. The consumer account mounts it as a database. No data is copied —
-- consumers query the provider's storage directly, with compute charged to
-- the consumer's warehouse credits.
--
-- Security controls:
--   • Shares can only be granted to named accounts (not public)
--   • Dynamic column masking and row access policies on shared objects are
--     enforced from the PROVIDER account — consumers cannot bypass them
--   • The share itself carries no compute cost for the provider
--
-- Run as: SYSADMIN (for share creation) + ACCOUNTADMIN (for account grants)
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- PROVIDER SIDE: Create a share for gold-layer analytics data
-- Run on the PROD account.
-- ---------------------------------------------------------------------------

CREATE SHARE IF NOT EXISTS ANALYTICS_SHARE
    COMMENT = 'Curated gold-layer data products shared to downstream analytics consumers.';

-- Grant access to the database and relevant schemas
GRANT USAGE ON DATABASE ANALYTICS_DB TO SHARE ANALYTICS_SHARE;
GRANT USAGE ON SCHEMA   ANALYTICS_DB.MARKETING   TO SHARE ANALYTICS_SHARE;
GRANT USAGE ON SCHEMA   ANALYTICS_DB.FINANCE      TO SHARE ANALYTICS_SHARE;
GRANT USAGE ON SCHEMA   ANALYTICS_DB.OPERATIONS   TO SHARE ANALYTICS_SHARE;
GRANT USAGE ON SCHEMA   ANALYTICS_DB.EXECUTIVE    TO SHARE ANALYTICS_SHARE;

-- Grant SELECT on specific gold tables (explicit > wildcard for least-privilege)
GRANT SELECT ON TABLE ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360      TO SHARE ANALYTICS_SHARE;
GRANT SELECT ON TABLE ANALYTICS_DB.FINANCE.GLD_REVENUE_SUMMARY      TO SHARE ANALYTICS_SHARE;
GRANT SELECT ON TABLE ANALYTICS_DB.OPERATIONS.GLD_PRODUCT_PERFORMANCE TO SHARE ANALYTICS_SHARE;

-- ---------------------------------------------------------------------------
-- GRANT THE SHARE TO CONSUMER ACCOUNTS
-- Run as ACCOUNTADMIN on the provider account.
-- Replace <ORG_NAME> and account names with actual values.
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- Grant to staging account (for pre-production testing of dashboards)
-- ALTER SHARE ANALYTICS_SHARE ADD ACCOUNTS = '<ORG_NAME>.<ACME-STAGING>';

-- Grant to a separate analytics/BI account (hub-and-spoke pattern)
-- ALTER SHARE ANALYTICS_SHARE ADD ACCOUNTS = '<ORG_NAME>.<ACME-BI>';

-- ---------------------------------------------------------------------------
-- CONSUMER SIDE: Mount the share as a database
-- Run on the CONSUMER account (e.g., staging or dedicated BI account).
-- ---------------------------------------------------------------------------

-- CREATE DATABASE IF NOT EXISTS PROD_ANALYTICS_SHARED
--     FROM SHARE <ORG_NAME>.<ACME-PROD>.ANALYTICS_SHARE
--     COMMENT = 'Read-only mount of production ANALYTICS_SHARE';

-- Grant access to the mounted share database to appropriate roles
-- GRANT IMPORTED PRIVILEGES ON DATABASE PROD_ANALYTICS_SHARED TO ROLE DATA_ANALYST_ROLE;
-- GRANT IMPORTED PRIVILEGES ON DATABASE PROD_ANALYTICS_SHARED TO ROLE POWERBI_ROLE;

-- ---------------------------------------------------------------------------
-- REFERENCE DATA SHARE
-- A lightweight share for reference tables used by multiple accounts
-- (e.g. country codes, product hierarchy, data domain definitions).
-- ---------------------------------------------------------------------------

USE ROLE SYSADMIN;

CREATE SHARE IF NOT EXISTS REFERENCE_DATA_SHARE
    COMMENT = 'Shared reference tables used across all environment accounts.';

GRANT USAGE  ON DATABASE FOUNDATION_DB                    TO SHARE REFERENCE_DATA_SHARE;
GRANT USAGE  ON SCHEMA   FOUNDATION_DB.REFERENCE          TO SHARE REFERENCE_DATA_SHARE;
GRANT SELECT ON ALL TABLES IN SCHEMA FOUNDATION_DB.REFERENCE TO SHARE REFERENCE_DATA_SHARE;

-- ---------------------------------------------------------------------------
-- MONITORING SHARE (from PROD to governance/ORGADMIN account)
-- Allows the central governance team to see prod data quality and audit logs
-- without requiring direct access to the production account.
-- ---------------------------------------------------------------------------

-- SHARING RESTRICTIONS that shape this section:
--   1. Only SECURE views (and tables) can be granted to a share.
--   2. Objects that reference an imported database — including all of the
--      MONITORING_DB views built over SNOWFLAKE.ACCOUNT_USAGE — cannot be
--      shared at all ("cannot re-share a share").
-- So: materialise the cost data into a LOCAL table on a schedule, then share
-- SECURE views over local tables only.

USE ROLE ACCOUNTADMIN;   -- owns the monitoring views/tables created earlier

CREATE SHARE IF NOT EXISTS MONITORING_SHARE
    COMMENT = 'Production audit and cost data shared to central governance account.';

-- Local snapshot of daily credit usage (refreshed daily; source view reads
-- ACCOUNT_USAGE, so the share exposes this local copy instead)
CREATE TABLE IF NOT EXISTS MONITORING_DB.COST_MANAGEMENT.CREDIT_USAGE_DAILY (
    usage_date              DATE,
    warehouse_name          VARCHAR(255),
    credits_used            NUMBER(38, 9),
    credits_compute         NUMBER(38, 9),
    credits_cloud_services  NUMBER(38, 9),
    estimated_cost_usd      NUMBER(38, 2),
    refreshed_at            TIMESTAMP_NTZ
);

CREATE TASK IF NOT EXISTS MONITORING_DB.COST_MANAGEMENT.TASK_REFRESH_CREDIT_USAGE_DAILY
    WAREHOUSE = ADMIN_WH
    SCHEDULE  = 'USING CRON 0 6 * * * UTC'   -- daily, after ACCOUNT_USAGE latency window
    COMMENT   = 'Materialises VW_DAILY_CREDIT_USAGE into a local, shareable table.'
AS
    INSERT OVERWRITE INTO MONITORING_DB.COST_MANAGEMENT.CREDIT_USAGE_DAILY
    SELECT
        usage_date,
        warehouse_name,
        credits_used,
        credits_compute,
        credits_cloud_services,
        estimated_cost_usd,
        CURRENT_TIMESTAMP()
    FROM MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDIT_USAGE;

-- ALTER TASK MONITORING_DB.COST_MANAGEMENT.TASK_REFRESH_CREDIT_USAGE_DAILY RESUME;

-- Secure views over LOCAL objects — these are shareable
CREATE OR REPLACE SECURE VIEW MONITORING_DB.COST_MANAGEMENT.SV_CREDIT_USAGE_DAILY AS
SELECT * FROM MONITORING_DB.COST_MANAGEMENT.CREDIT_USAGE_DAILY;

CREATE OR REPLACE SECURE VIEW MONITORING_DB.DATA_QUALITY.SV_DBT_TEST_RESULTS AS
SELECT * FROM MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS;

GRANT USAGE  ON DATABASE MONITORING_DB                  TO SHARE MONITORING_SHARE;
GRANT USAGE  ON SCHEMA   MONITORING_DB.COST_MANAGEMENT  TO SHARE MONITORING_SHARE;
GRANT USAGE  ON SCHEMA   MONITORING_DB.DATA_QUALITY     TO SHARE MONITORING_SHARE;
GRANT SELECT ON VIEW MONITORING_DB.COST_MANAGEMENT.SV_CREDIT_USAGE_DAILY TO SHARE MONITORING_SHARE;
GRANT SELECT ON VIEW MONITORING_DB.DATA_QUALITY.SV_DBT_TEST_RESULTS      TO SHARE MONITORING_SHARE;

-- NOTE: MONITORING_DB.AUDIT is intentionally excluded from the share.
-- Audit logs contain sensitive login and query history; expose only to
-- the governance account via replication (03_account_replication.sql)
-- rather than a share, so the governance team has their own isolated copy.

-- ---------------------------------------------------------------------------
-- SECURE VIEW PATTERN FOR SHARING
-- When sharing requires an additional filtering layer (e.g., sharing a
-- multi-tenant gold table where the consumer should see only their tenant),
-- create a SECURE VIEW and share the view instead of the base table.
-- Secure views hide their definition from the consumer.
-- ---------------------------------------------------------------------------

-- Example: create a secure filtered view before adding to a share
-- CREATE OR REPLACE SECURE VIEW ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360_SHARED AS
-- SELECT * FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
-- WHERE data_domain = 'MARKETING';        -- enforce domain filter at share boundary
--
-- GRANT SELECT ON VIEW ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360_SHARED
--     TO SHARE ANALYTICS_SHARE;

-- ---------------------------------------------------------------------------
-- VERIFY SHARES
-- ---------------------------------------------------------------------------
-- SHOW SHARES;
-- DESCRIBE SHARE ANALYTICS_SHARE;
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.SHARE_CONSUMPTION_HISTORY
-- ORDER BY start_time DESC;
