-- =============================================================================
-- 04_row_access_policies.sql
-- Row Access Policies (RAP) control which rows a role can see.
-- Used primarily for:
--   1. Power BI domain isolation — POWERBI_MARKETING_ROLE sees marketing rows only
--   2. Multi-tenant data — restrict rows by tenant_id based on the calling user
--   3. Data residency — restrict rows to specific geographic regions
--
-- RLS for Power BI works by:
--   a) Assigning Snowflake roles to AD groups via SAML attribute mapping
--   b) Row access policy checks CURRENT_ROLE() (or CURRENT_USER()) at query time
--   c) No row-level grants needed; policy is transparent to the BI tool
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE FOUNDATION_DB;

CREATE SCHEMA IF NOT EXISTS FOUNDATION_DB.ROW_POLICIES
    COMMENT = 'Holds row access policy objects.';

GRANT USAGE ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE SECURITYADMIN;
GRANT USAGE ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE DATA_ENGINEER_ROLE;
GRANT USAGE ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE TRANSFORMER_ROLE;

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- POLICY 1: DOMAIN-BASED ROW ACCESS
-- Applied to gold-layer tables that contain rows spanning multiple business domains.
-- POWERBI_MARKETING_ROLE sees rows where data_domain = 'MARKETING'.
-- POWERBI_FINANCE_ROLE sees rows where data_domain = 'FINANCE'.
-- Engineers and analysts see all rows.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    AS (data_domain VARCHAR) RETURNS BOOLEAN ->
    CASE
        -- Admins and engineers see everything
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN', 'SYSADMIN', 'DATA_ENGINEER_ROLE',
            'TRANSFORMER_ROLE', 'DATA_ANALYST_ROLE', 'DATA_SCIENTIST_ROLE'
        ) THEN TRUE

        -- PowerBI service account sees all rows
        WHEN CURRENT_ROLE() = 'POWERBI_ROLE' THEN TRUE

        -- Domain-scoped PBI roles see only their domain
        WHEN CURRENT_ROLE() = 'POWERBI_MARKETING_ROLE'
            THEN data_domain = 'MARKETING'

        WHEN CURRENT_ROLE() = 'POWERBI_FINANCE_ROLE'
            THEN data_domain = 'FINANCE'

        WHEN CURRENT_ROLE() = 'POWERBI_OPERATIONS_ROLE'
            THEN data_domain IN ('OPERATIONS', 'SUPPLY_CHAIN')

        -- Default deny
        ELSE FALSE
    END;

-- ---------------------------------------------------------------------------
-- POLICY 2: TENANT ISOLATION
-- For multi-tenant gold tables, each customer sees only their own rows.
-- Tenant ID is resolved from a mapping table keyed on CURRENT_USER().
-- ---------------------------------------------------------------------------

-- Supporting mapping table: maps Snowflake user → tenant_id
CREATE TABLE IF NOT EXISTS FOUNDATION_DB.ROW_POLICIES.USER_TENANT_MAP (
    snowflake_user  VARCHAR(255) NOT NULL,
    tenant_id       VARCHAR(100) NOT NULL,
    role_name       VARCHAR(255),
    active          BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (snowflake_user, tenant_id)
);

GRANT SELECT ON TABLE FOUNDATION_DB.ROW_POLICIES.USER_TENANT_MAP
    TO ROLE SECURITYADMIN;
GRANT SELECT ON TABLE FOUNDATION_DB.ROW_POLICIES.USER_TENANT_MAP
    TO ROLE TRANSFORMER_ROLE;  -- policy must be evaluable by all callers

CREATE OR REPLACE ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.TENANT_ISOLATION_POLICY
    AS (tenant_id VARCHAR) RETURNS BOOLEAN ->
    CASE
        -- Internal roles see all tenants
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN', 'SYSADMIN', 'DATA_ENGINEER_ROLE', 'TRANSFORMER_ROLE'
        ) THEN TRUE

        -- External / analyst roles: match tenant via user mapping
        ELSE EXISTS (
            SELECT 1
            FROM FOUNDATION_DB.ROW_POLICIES.USER_TENANT_MAP utm
            WHERE utm.snowflake_user = CURRENT_USER()
              AND utm.tenant_id      = tenant_id
              AND utm.active         = TRUE
        )
    END;

-- ---------------------------------------------------------------------------
-- POLICY 3: REGIONAL DATA RESIDENCY
-- Ensures users in a region only see data flagged for their region.
-- Useful for GDPR data residency requirements.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.REGION_RESIDENCY_POLICY
    AS (data_region VARCHAR) RETURNS BOOLEAN ->
    CASE
        WHEN CURRENT_ROLE() IN (
            'ACCOUNTADMIN', 'SYSADMIN', 'DATA_ENGINEER_ROLE', 'TRANSFORMER_ROLE'
        ) THEN TRUE

        -- EU-based analysts see only EU and GLOBAL data
        WHEN CURRENT_ROLE() IN ('DATA_ANALYST_ROLE', 'DATA_SCIENTIST_ROLE')
            THEN data_region IN ('EU', 'GLOBAL', 'UK')

        -- Power BI roles see appropriate regional data
        WHEN CURRENT_ROLE() LIKE 'POWERBI%'
            THEN data_region IN ('EU', 'GLOBAL', 'UK')

        ELSE FALSE
    END;

-- ---------------------------------------------------------------------------
-- GRANT APPLY privilege
-- ---------------------------------------------------------------------------

GRANT APPLY ON ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    TO ROLE SECURITYADMIN;
GRANT APPLY ON ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.TENANT_ISOLATION_POLICY
    TO ROLE SECURITYADMIN;
GRANT APPLY ON ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.REGION_RESIDENCY_POLICY
    TO ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- EXAMPLE POLICY APPLICATION
-- ---------------------------------------------------------------------------

-- Apply domain policy to the gold executive summary table
-- ALTER TABLE ANALYTICS_DB.EXECUTIVE.KPI_SUMMARY
--     ADD ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
--     ON (DATA_DOMAIN);

-- Apply tenant isolation to a multi-tenant metrics table
-- ALTER TABLE ANALYTICS_DB.MARKETING.CUSTOMER_METRICS
--     ADD ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.TENANT_ISOLATION_POLICY
--     ON (TENANT_ID);

-- ---------------------------------------------------------------------------
-- VIEW: ROW ACCESS POLICY INVENTORY
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_ROW_ACCESS_POLICY_COVERAGE AS
SELECT
    pr.policy_name,
    pr.ref_database_name,
    pr.ref_schema_name,
    pr.ref_entity_name   AS table_name,
    pr.ref_column_name   AS column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES pr
WHERE pr.policy_kind = 'ROW_ACCESS_POLICY'
ORDER BY pr.ref_database_name, pr.ref_schema_name, pr.ref_entity_name;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_ROW_ACCESS_POLICY_COVERAGE
    TO ROLE DATA_ENGINEER_ROLE;
