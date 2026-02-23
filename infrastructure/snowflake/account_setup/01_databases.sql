-- =============================================================================
-- 01_databases.sql
-- Creates all databases for the medallion architecture.
-- Run as: ACCOUNTADMIN (or SYSADMIN after granting privileges)
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- MEDALLION LAYER DATABASES
-- ---------------------------------------------------------------------------

-- Bronze: Raw, unmodified data from all source systems.
-- Data is immutable once landed; no transforms applied.
CREATE DATABASE IF NOT EXISTS RAW_DB
    DATA_RETENTION_TIME_IN_DAYS = 14
    COMMENT = 'Bronze layer — raw ingestion from all source systems. Immutable.';

-- Foundation (Silver): Cleansed, validated, conformed data.
-- Single source of truth for business entities.
CREATE DATABASE IF NOT EXISTS FOUNDATION_DB
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Silver layer — cleansed, validated, and conformed data. Single source of truth.';

-- Analytics (Gold): Curated, business-domain-oriented data products.
-- Optimised for BI and analytical consumption.
CREATE DATABASE IF NOT EXISTS ANALYTICS_DB
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Gold layer — curated data products for business consumption.';

-- ---------------------------------------------------------------------------
-- OPERATIONAL DATABASES
-- ---------------------------------------------------------------------------

-- Monitoring: Centralised audit logs, query history summaries, cost tracking.
CREATE DATABASE IF NOT EXISTS MONITORING_DB
    DATA_RETENTION_TIME_IN_DAYS = 90
    COMMENT = 'Operational monitoring — audit logs, cost tracking, data quality metrics.';

-- dbt artifacts: Stores dbt run results, manifest, and catalog for lineage.
CREATE DATABASE IF NOT EXISTS DBT_ARTIFACTS_DB
    DATA_RETENTION_TIME_IN_DAYS = 7
    COMMENT = 'dbt run metadata — manifests, results, and catalog for lineage tracking.';

-- ---------------------------------------------------------------------------
-- NON-PRODUCTION DATABASES (cloned from prod on demand)
-- ---------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS DEV_DB
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'Development environment — individual developer sandboxes.';

CREATE DATABASE IF NOT EXISTS TEST_DB
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'CI/test environment — ephemeral, used by CI pipeline.';

-- ---------------------------------------------------------------------------
-- SCHEMAS: RAW_DB (Bronze)
-- Separate schema per source system for lineage and access control clarity.
-- ---------------------------------------------------------------------------

USE DATABASE RAW_DB;

CREATE SCHEMA IF NOT EXISTS SQLSERVER_RAW
    DATA_RETENTION_TIME_IN_DAYS = 14
    COMMENT = 'Raw data loaded from legacy SQL Server via ADF / Fivetran.';

CREATE SCHEMA IF NOT EXISTS S3_RAW
    DATA_RETENTION_TIME_IN_DAYS = 14
    COMMENT = 'Raw data landed in S3 and auto-ingested via Snowpipe.';

CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_NATIVE_RAW
    DATA_RETENTION_TIME_IN_DAYS = 14
    COMMENT = 'Data originating from Snowflake Marketplace or native Snowflake sources.';

CREATE SCHEMA IF NOT EXISTS LANDING
    DATA_RETENTION_TIME_IN_DAYS = 7
    COMMENT = 'Transient landing zone for streamed / partial loads before promotion to source schema.';

-- ---------------------------------------------------------------------------
-- SCHEMAS: FOUNDATION_DB (Silver)
-- ---------------------------------------------------------------------------

USE DATABASE FOUNDATION_DB;

CREATE SCHEMA IF NOT EXISTS CUSTOMERS
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Conformed customer entities from all sources.';

CREATE SCHEMA IF NOT EXISTS ORDERS
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Conformed order and transaction entities.';

CREATE SCHEMA IF NOT EXISTS PRODUCTS
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Conformed product catalogue entities.';

CREATE SCHEMA IF NOT EXISTS EVENTS
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Cleansed behavioural / event stream data.';

CREATE SCHEMA IF NOT EXISTS REFERENCE
    DATA_RETENTION_TIME_IN_DAYS = 90
    COMMENT = 'Reference / lookup tables (currency, geography, calendar).';

-- ---------------------------------------------------------------------------
-- SCHEMAS: ANALYTICS_DB (Gold)
-- Domain-oriented schemas aligned with business units.
-- ---------------------------------------------------------------------------

USE DATABASE ANALYTICS_DB;

CREATE SCHEMA IF NOT EXISTS MARKETING
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Gold data products for the Marketing domain.';

CREATE SCHEMA IF NOT EXISTS FINANCE
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Gold data products for the Finance domain.';

CREATE SCHEMA IF NOT EXISTS OPERATIONS
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Gold data products for Operations / Supply Chain.';

CREATE SCHEMA IF NOT EXISTS EXECUTIVE
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Executive-level KPI summaries and dashboards.';

-- ---------------------------------------------------------------------------
-- SCHEMAS: MONITORING_DB
-- ---------------------------------------------------------------------------

USE DATABASE MONITORING_DB;

CREATE SCHEMA IF NOT EXISTS AUDIT
    DATA_RETENTION_TIME_IN_DAYS = 90
    COMMENT = 'Audit log tables and views over ACCOUNT_USAGE / INFORMATION_SCHEMA.';

CREATE SCHEMA IF NOT EXISTS COST_MANAGEMENT
    DATA_RETENTION_TIME_IN_DAYS = 90
    COMMENT = 'Credit consumption tracking and showback / chargeback reports.';

CREATE SCHEMA IF NOT EXISTS DATA_QUALITY
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'dbt test results and data quality trend metrics.';
