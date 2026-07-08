-- =============================================================================
-- 05_managed_access_schemas.sql
-- Enables managed access on all production schemas.
--
-- CIS Snowflake Foundations Benchmark controls addressed:
--   CIS 3.5 — Ensure managed access schemas are used to centralise privilege grants
--
-- Why this matters:
--   In a regular schema, the schema OWNER can grant their owned objects to any
--   role — including roles that shouldn't have access (privilege escalation).
--   With MANAGED ACCESS, only SECURITYADMIN (or a role with MANAGE GRANTS) can
--   issue GRANT statements on objects inside the schema, regardless of ownership.
--   This is a critical control for environments where dbt (TRANSFORMER_ROLE)
--   owns the tables it creates: without managed access, a compromised dbt
--   credential could re-grant table access to an unapproved role.
--
-- PREREQUISITE: The executing role must OWN all objects in each schema, OR have
-- the global MANAGE GRANTS privilege. Running as ACCOUNTADMIN satisfies this.
-- If ALTER SCHEMA fails with a privilege error, first run:
--   GRANT OWNERSHIP ON ALL TABLES IN SCHEMA <schema> TO ROLE ACCOUNTADMIN COPY CURRENT GRANTS;
--
-- Run as: ACCOUNTADMIN
--
-- GOVERNMENT / PUBLIC SECTOR NOTES
-- ---------------------------------
-- • Managed access schemas directly support NIST SP 800-53 control AC-5
--   (Separation of Duties): object owners cannot grant their own objects,
--   enforcing a second-party approval model for any access expansion.
-- • For DoD RMF, this control contributes evidence for AC-6 (Least Privilege)
--   in the System Security Plan (SSP). Reference this script and the
--   ACCOUNT_USAGE.SCHEMATA verification query in your CCM/POAM tracking.
-- • In FedRAMP systems where a contractor holds TRANSFORMER_ROLE (e.g., a
--   system integrator running dbt), managed access ensures that contractor
--   cannot self-provision access to government data without agency approval.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- FOUNDATION_DB (Silver layer) — managed access on all data schemas
-- ---------------------------------------------------------------------------

ALTER SCHEMA FOUNDATION_DB.CUSTOMERS   ENABLE MANAGED ACCESS;
ALTER SCHEMA FOUNDATION_DB.ORDERS      ENABLE MANAGED ACCESS;
ALTER SCHEMA FOUNDATION_DB.PRODUCTS    ENABLE MANAGED ACCESS;
ALTER SCHEMA FOUNDATION_DB.EVENTS      ENABLE MANAGED ACCESS;
ALTER SCHEMA FOUNDATION_DB.REFERENCE   ENABLE MANAGED ACCESS;
ALTER SCHEMA FOUNDATION_DB.SNAPSHOTS   ENABLE MANAGED ACCESS;   -- created in 01_databases.sql; populated by dbt snapshots
-- Policy-object schemas: managed access prevents unauthorised policy modifications
ALTER SCHEMA FOUNDATION_DB.ROW_POLICIES ENABLE MANAGED ACCESS;
ALTER SCHEMA FOUNDATION_DB.MASKING      ENABLE MANAGED ACCESS;

-- ---------------------------------------------------------------------------
-- ANALYTICS_DB (Gold layer) — managed access on all domain schemas
-- ---------------------------------------------------------------------------

ALTER SCHEMA ANALYTICS_DB.MARKETING   ENABLE MANAGED ACCESS;
ALTER SCHEMA ANALYTICS_DB.FINANCE     ENABLE MANAGED ACCESS;
ALTER SCHEMA ANALYTICS_DB.OPERATIONS  ENABLE MANAGED ACCESS;
ALTER SCHEMA ANALYTICS_DB.EXECUTIVE   ENABLE MANAGED ACCESS;

-- ---------------------------------------------------------------------------
-- RAW_DB (Bronze layer) — managed access on ingestion schemas
-- ---------------------------------------------------------------------------

ALTER SCHEMA RAW_DB.SQLSERVER_RAW       ENABLE MANAGED ACCESS;
ALTER SCHEMA RAW_DB.S3_RAW              ENABLE MANAGED ACCESS;
ALTER SCHEMA RAW_DB.SNOWFLAKE_NATIVE_RAW ENABLE MANAGED ACCESS;
ALTER SCHEMA RAW_DB.LANDING             ENABLE MANAGED ACCESS;
ALTER SCHEMA RAW_DB.BRONZE              ENABLE MANAGED ACCESS;  -- dbt-managed bronze views

-- ---------------------------------------------------------------------------
-- MONITORING_DB — managed access on audit and quality schemas
-- ---------------------------------------------------------------------------

ALTER SCHEMA MONITORING_DB.AUDIT            ENABLE MANAGED ACCESS;
ALTER SCHEMA MONITORING_DB.COST_MANAGEMENT  ENABLE MANAGED ACCESS;
ALTER SCHEMA MONITORING_DB.DATA_QUALITY     ENABLE MANAGED ACCESS;

-- ---------------------------------------------------------------------------
-- IMPORTANT: After enabling managed access, all future GRANTs on objects
-- within these schemas must be executed by SECURITYADMIN (or a role with
-- MANAGE GRANTS privilege). TRANSFORMER_ROLE (dbt) can still CREATE and
-- own objects, but cannot re-grant access to them — that remains with SECURITYADMIN.
--
-- If dbt needs to grant access to a newly created table, add the GRANT to
-- a post-hook macro that runs as SECURITYADMIN, or manage grants separately
-- in 03_roles.sql using FUTURE GRANTS.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FUTURE GRANTS PATTERN (run as SECURITYADMIN)
-- These cover objects dbt creates in the future inside managed access schemas.
-- ---------------------------------------------------------------------------

USE ROLE SECURITYADMIN;

-- Silver: analysts and scientists can read future tables/views
GRANT SELECT ON FUTURE TABLES IN DATABASE FOUNDATION_DB TO ROLE DATA_ANALYST_ROLE;
GRANT SELECT ON FUTURE TABLES IN DATABASE FOUNDATION_DB TO ROLE DATA_SCIENTIST_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN DATABASE FOUNDATION_DB TO ROLE DATA_ANALYST_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN DATABASE FOUNDATION_DB TO ROLE DATA_SCIENTIST_ROLE;

-- Gold: analysts, scientists, and PowerBI roles can read future tables/views
GRANT SELECT ON FUTURE TABLES IN DATABASE ANALYTICS_DB TO ROLE DATA_ANALYST_ROLE;
GRANT SELECT ON FUTURE TABLES IN DATABASE ANALYTICS_DB TO ROLE DATA_SCIENTIST_ROLE;
GRANT SELECT ON FUTURE TABLES IN DATABASE ANALYTICS_DB TO ROLE POWERBI_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN DATABASE ANALYTICS_DB TO ROLE DATA_ANALYST_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN DATABASE ANALYTICS_DB TO ROLE DATA_SCIENTIST_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN DATABASE ANALYTICS_DB TO ROLE POWERBI_ROLE;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- Check managed access is enabled (is_managed_access = true):
-- SELECT catalog_name, schema_name, is_managed_access
-- FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
-- WHERE is_managed_access = 'YES'
-- ORDER BY catalog_name, schema_name;
