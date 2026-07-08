-- =============================================================================
-- 04_row_access_policies.sql
-- Row Access Policies (RAP) control which rows a role can see.
-- Used primarily for:
--   1. Power BI domain isolation — POWERBI_MARKETING_ROLE sees marketing rows only
--   2. Multi-tenant data — restrict rows by tenant_id based on the calling user
--   3. Data residency — restrict rows to specific geographic regions
--
-- RLS for Power BI works by:
--   a) Assigning Snowflake roles to AD groups via SCIM group sync
--   b) Row access policy checks IS_ROLE_IN_SESSION() / CURRENT_USER() at query time
--   c) No row-level grants needed; policy is transparent to the BI tool
--   NOTE: per-user enforcement requires each user to hit Snowflake under their
--   own identity (DirectQuery + AAD SSO). Import-mode datasets refreshed by the
--   SVC_POWERBI service account contain whatever that role can see — see
--   powerbi/saml_oauth_setup.md for the two connectivity models.
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE SYSADMIN;

CREATE SCHEMA IF NOT EXISTS FOUNDATION_DB.ROW_POLICIES
    COMMENT = 'Holds row access policy objects.';

GRANT USAGE ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE SECURITYADMIN;
GRANT USAGE ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE DATA_ENGINEER_ROLE;
GRANT USAGE ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE TRANSFORMER_ROLE;

-- ---------------------------------------------------------------------------
-- POLICY ADMINISTRATION PRIVILEGES
-- SECURITYADMIN owns the policy objects and the tenant mapping table, and can
-- attach policies to tables it does NOT own via the account-level APPLY ROW
-- ACCESS POLICY privilege (dbt / TRANSFORMER_ROLE owns the data tables).
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
GRANT CREATE ROW ACCESS POLICY ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE SECURITYADMIN;
GRANT CREATE TABLE             ON SCHEMA FOUNDATION_DB.ROW_POLICIES TO ROLE SECURITYADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE SECURITYADMIN;
-- TRANSFORMER_ROLE re-attaches policies from dbt post-hooks after each rebuild.
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE TRANSFORMER_ROLE;

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- POLICY 1: DOMAIN-BASED ROW ACCESS
-- Applied to gold-layer tables that contain rows spanning multiple business domains.
-- POWERBI_MARKETING_ROLE sees rows where data_domain = 'MARKETING'.
-- POWERBI_FINANCE_ROLE sees rows where data_domain = 'FINANCE'.
-- Engineers and analysts see all rows.
-- ---------------------------------------------------------------------------

-- IS_ROLE_IN_SESSION() (not CURRENT_ROLE()) so that role hierarchy and
-- secondary roles behave correctly, and so a user granted multiple domain
-- roles sees the UNION of their domains. Default deny: no clause → FALSE.
CREATE OR REPLACE ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    AS (data_domain VARCHAR) RETURNS BOOLEAN ->
    -- Internal roles and the Power BI gateway service account see everything
    -- (SYSADMIN / ACCOUNTADMIN inherit these roles)
       IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
    OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
    OR IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
    OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
    OR IS_ROLE_IN_SESSION('POWERBI_ROLE')
    -- Domain-scoped PBI roles see only their domain's rows
    OR (IS_ROLE_IN_SESSION('POWERBI_MARKETING_ROLE')  AND data_domain = 'MARKETING')
    OR (IS_ROLE_IN_SESSION('POWERBI_FINANCE_ROLE')    AND data_domain = 'FINANCE')
    OR (IS_ROLE_IN_SESSION('POWERBI_OPERATIONS_ROLE') AND data_domain IN ('OPERATIONS', 'SUPPLY_CHAIN'));

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

-- No SELECT grants are needed for callers: row access policies evaluate the
-- mapping-table subquery with the POLICY OWNER's rights (SECURITYADMIN, which
-- owns this table), not the querying user's rights.

-- NOTE: the policy argument is deliberately named ARG_TENANT_ID. If it were
-- named TENANT_ID, the unqualified reference inside the EXISTS subquery would
-- bind to UTM.TENANT_ID (making the predicate always true) and every mapped
-- user would see every tenant's rows.
CREATE OR REPLACE ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.TENANT_ISOLATION_POLICY
    AS (arg_tenant_id VARCHAR) RETURNS BOOLEAN ->
    -- Internal roles see all tenants (admins inherit these via hierarchy)
       IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
    OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
    -- External / analyst roles: match tenant via user mapping
    OR EXISTS (
        SELECT 1
        FROM FOUNDATION_DB.ROW_POLICIES.USER_TENANT_MAP utm
        WHERE utm.snowflake_user = CURRENT_USER()
          AND utm.tenant_id      = arg_tenant_id
          AND utm.active         = TRUE
    );

-- ---------------------------------------------------------------------------
-- POLICY 3: REGIONAL DATA RESIDENCY
-- Ensures users in a region only see data flagged for their region.
-- Useful for GDPR data residency requirements.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.REGION_RESIDENCY_POLICY
    AS (data_region VARCHAR) RETURNS BOOLEAN ->
    -- Internal platform roles see all regions (admins inherit via hierarchy)
       IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
    OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
    -- Analyst and Power BI populations in this deployment are EU-based:
    -- they see EU, UK, and GLOBAL rows only. Adjust per region rollout,
    -- or resolve regions from ref_country_regions for finer control.
    OR (
        (   IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
         OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
         OR IS_ROLE_IN_SESSION('POWERBI_ROLE')
         OR IS_ROLE_IN_SESSION('POWERBI_MARKETING_ROLE')
         OR IS_ROLE_IN_SESSION('POWERBI_FINANCE_ROLE')
         OR IS_ROLE_IN_SESSION('POWERBI_OPERATIONS_ROLE')
        )
        AND data_region IN ('EU', 'GLOBAL', 'UK')
    );

-- ---------------------------------------------------------------------------
-- GRANT APPLY privilege
-- SECURITYADMIN owns the policies; grant per-policy APPLY to TRANSFORMER_ROLE
-- so dbt post-hooks can re-attach them whenever a gold table is rebuilt.
-- ---------------------------------------------------------------------------

GRANT APPLY ON ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.TENANT_ISOLATION_POLICY
    TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.REGION_RESIDENCY_POLICY
    TO ROLE TRANSFORMER_ROLE;

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
