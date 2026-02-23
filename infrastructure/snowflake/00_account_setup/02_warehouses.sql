-- =============================================================================
-- 02_warehouses.sql
-- Creates virtual warehouses sized and configured per workload type.
-- Enforces auto-suspend to minimise idle credit consumption.
-- Run as: SYSADMIN
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- INGESTION WAREHOUSE
-- Used by: Snowpipe (serverless), ADF, Fivetran service accounts, COPY commands.
-- Strategy: Small, always fast to resume — loading jobs are typically short bursts.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS INGESTION_WH
    WAREHOUSE_SIZE         = 'X-SMALL'
    AUTO_SUSPEND           = 60          -- seconds; suspend after 1 min idle
    AUTO_RESUME            = TRUE
    INITIALLY_SUSPENDED    = TRUE
    MAX_CLUSTER_COUNT      = 2           -- multi-cluster for concurrent loads
    MIN_CLUSTER_COUNT      = 1
    SCALING_POLICY         = 'ECONOMY'
    COMMENT                = 'Data ingestion — Snowpipe, ADF, Fivetran, COPY INTO jobs.';

-- ---------------------------------------------------------------------------
-- TRANSFORMATION WAREHOUSE
-- Used by: dbt (TRANSFORMER_ROLE service account), scheduled stored procedures.
-- Strategy: Medium with aggressive auto-suspend; dbt runs are bursty.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS TRANSFORM_WH
    WAREHOUSE_SIZE         = 'MEDIUM'
    AUTO_SUSPEND           = 120
    AUTO_RESUME            = TRUE
    INITIALLY_SUSPENDED    = TRUE
    MAX_CLUSTER_COUNT      = 3
    MIN_CLUSTER_COUNT      = 1
    SCALING_POLICY         = 'ECONOMY'
    COMMENT                = 'dbt transformations and scheduled stored procedures.';

-- ---------------------------------------------------------------------------
-- ANALYTICS WAREHOUSE
-- Used by: Power BI gateway, SQL analysts, dashboards.
-- Strategy: Medium with multi-cluster to handle concurrent BI queries.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS ANALYTICS_WH
    WAREHOUSE_SIZE         = 'MEDIUM'
    AUTO_SUSPEND           = 300         -- 5 min — keep warm during business hours via task
    AUTO_RESUME            = TRUE
    INITIALLY_SUSPENDED    = TRUE
    MAX_CLUSTER_COUNT      = 4
    MIN_CLUSTER_COUNT      = 1
    SCALING_POLICY         = 'STANDARD'  -- scale fast for interactive queries
    COMMENT                = 'Business intelligence and analyst ad-hoc queries (Power BI, SQL).';

-- ---------------------------------------------------------------------------
-- DATA SCIENCE WAREHOUSE
-- Used by: DATA_SCIENTIST_ROLE — exploratory queries, model training prep.
-- Strategy: Larger size, longer suspend window for iterative workloads.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS DATASCIENCE_WH
    WAREHOUSE_SIZE         = 'LARGE'
    AUTO_SUSPEND           = 600         -- 10 min
    AUTO_RESUME            = TRUE
    INITIALLY_SUSPENDED    = TRUE
    MAX_CLUSTER_COUNT      = 1
    MIN_CLUSTER_COUNT      = 1
    COMMENT                = 'Data science and ML feature engineering workloads.';

-- ---------------------------------------------------------------------------
-- ADMIN WAREHOUSE
-- Used by: ACCOUNTADMIN, SYSADMIN, SECURITYADMIN for platform management.
-- Strategy: XSmall — admin tasks are infrequent; cost control.
-- ---------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS ADMIN_WH
    WAREHOUSE_SIZE         = 'X-SMALL'
    AUTO_SUSPEND           = 60
    AUTO_RESUME            = TRUE
    INITIALLY_SUSPENDED    = TRUE
    MAX_CLUSTER_COUNT      = 1
    MIN_CLUSTER_COUNT      = 1
    COMMENT                = 'Platform administration tasks — DDL, access control, audit queries.';

-- ---------------------------------------------------------------------------
-- SNOWPIPE (Serverless) — no explicit warehouse needed; billed per file.
-- Snowpipe uses its own internal compute pool. See integrations/02_external_stages.sql.
-- ---------------------------------------------------------------------------
