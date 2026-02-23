-- =============================================================================
-- rls_snowflake_setup.sql
-- Apply Snowflake Row Access Policies to gold layer tables for Power BI RLS.
--
-- This script is the final step after:
--   1. Gold tables have been created by dbt
--   2. Row access policies have been defined (04_row_access_policies.sql)
--   3. Power BI OAuth integration is configured (saml_oauth_setup.md)
--
-- Run as: SECURITYADMIN
-- Re-run if new gold tables are added.
-- =============================================================================

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- APPLY DOMAIN_ACCESS_POLICY TO GOLD TABLES
-- The policy filters rows based on DATA_DOMAIN column value vs CURRENT_ROLE().
-- ---------------------------------------------------------------------------

-- Customer 360 (Marketing domain)
ALTER TABLE ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
    ADD ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    ON (DATA_DOMAIN);

-- Revenue Summary (Finance domain)
ALTER TABLE ANALYTICS_DB.FINANCE.GLD_REVENUE_SUMMARY
    ADD ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    ON (DATA_DOMAIN);

-- Product Performance (Operations domain)
ALTER TABLE ANALYTICS_DB.OPERATIONS.GLD_PRODUCT_PERFORMANCE
    ADD ROW ACCESS POLICY FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
    ON (DATA_DOMAIN);

-- ---------------------------------------------------------------------------
-- APPLY COLUMN MASKING POLICIES TO PII COLUMNS IN GOLD TABLES
-- Masking is applied at column level; evaluated at query time per CURRENT_ROLE().
-- ---------------------------------------------------------------------------

-- Customer 360: PII columns
ALTER TABLE ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
    MODIFY COLUMN EMAIL_ADDRESS
        SET MASKING POLICY FOUNDATION_DB.MASKING.EMAIL_MASK;

ALTER TABLE ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
    MODIFY COLUMN FULL_NAME
        SET MASKING POLICY FOUNDATION_DB.MASKING.NAME_MASK;

ALTER TABLE ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
    MODIFY COLUMN PHONE_NUMBER
        SET MASKING POLICY FOUNDATION_DB.MASKING.PHONE_MASK;

-- ---------------------------------------------------------------------------
-- VERIFY POLICIES APPLIED
-- ---------------------------------------------------------------------------

-- Check row access policies
SELECT
    policy_name,
    ref_database_name,
    ref_schema_name,
    ref_entity_name,
    ref_column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE policy_kind = 'ROW_ACCESS_POLICY'
  AND ref_database_name = 'ANALYTICS_DB'
ORDER BY ref_schema_name, ref_entity_name;

-- Check masking policies
SELECT
    policy_name,
    ref_database_name,
    ref_schema_name,
    ref_entity_name,
    ref_column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE policy_kind = 'MASKING_POLICY'
  AND ref_database_name = 'ANALYTICS_DB'
ORDER BY ref_schema_name, ref_entity_name, ref_column_name;

-- ---------------------------------------------------------------------------
-- ROLE-LEVEL TEST QUERIES
-- Run these as the respective roles to verify RLS is working.
-- ---------------------------------------------------------------------------

-- Test as POWERBI_MARKETING_ROLE:
-- USE ROLE POWERBI_MARKETING_ROLE;
-- SELECT DISTINCT data_domain FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360;
-- Expected: only 'MARKETING' rows returned

-- Test as POWERBI_FINANCE_ROLE:
-- USE ROLE POWERBI_FINANCE_ROLE;
-- SELECT DISTINCT data_domain FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360;
-- Expected: 0 rows (Marketing table not visible to Finance role)

-- Test email masking as POWERBI_MARKETING_ROLE:
-- USE ROLE POWERBI_MARKETING_ROLE;
-- SELECT email_address FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360 LIMIT 5;
-- Expected: '***@***.***' (fully masked)

-- Test email masking as DATA_ANALYST_ROLE:
-- USE ROLE DATA_ANALYST_ROLE;
-- SELECT email_address FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360 LIMIT 5;
-- Expected: 'j***@example.com' (partial mask — local part obfuscated, domain shown)

-- Test full access as DATA_ENGINEER_ROLE:
-- USE ROLE DATA_ENGINEER_ROLE;
-- SELECT email_address FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360 LIMIT 5;
-- Expected: full email address visible
