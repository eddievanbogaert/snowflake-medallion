-- =============================================================================
-- 03_column_masking_policies.sql
-- Dynamic Data Masking policies for PII columns.
--
-- Masking logic:
--   • Unmasked:  DATA_ENGINEER_ROLE, TRANSFORMER_ROLE (and, via role
--                hierarchy, SYSADMIN / ACCOUNTADMIN which inherit them)
--   • Partial:   DATA_ANALYST_ROLE, DATA_SCIENTIST_ROLE (e.g. email → j***@domain.com)
--   • Fully:     POWERBI_* roles and any other reader role
--   • NULL:      All others / unknown callers
--
-- WHY IS_ROLE_IN_SESSION() AND NOT CURRENT_ROLE():
--   CURRENT_ROLE() only returns the session's primary role. Secondary roles
--   are enabled by default (ALLOWED_SECONDARY_ROLES = ALL), and role
--   inheritance means an admin whose primary role is SYSADMIN would be
--   MASKED under a CURRENT_ROLE() check even though SYSADMIN inherits
--   DATA_ENGINEER_ROLE. IS_ROLE_IN_SESSION() evaluates the full active role
--   hierarchy (primary + inherited + secondary), which is Snowflake's
--   recommended pattern for masking and row access policies.
--
-- Policies are applied to columns via the dbt post-hook (see
-- dbt/macros/security_policies.sql) driven by column meta.masking_policy,
-- and initially via powerbi/row_level_security/rls_snowflake_setup.sql.
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

-- ---------------------------------------------------------------------------
-- HELPER: Schema to hold masking policies
-- ---------------------------------------------------------------------------

USE ROLE SYSADMIN;
CREATE SCHEMA IF NOT EXISTS FOUNDATION_DB.MASKING
    COMMENT = 'Holds dynamic data masking policy objects.';

GRANT USAGE ON SCHEMA FOUNDATION_DB.MASKING TO ROLE SECURITYADMIN;
GRANT USAGE ON SCHEMA FOUNDATION_DB.MASKING TO ROLE TRANSFORMER_ROLE;
GRANT USAGE ON SCHEMA FOUNDATION_DB.MASKING TO ROLE DATA_ENGINEER_ROLE;

-- ---------------------------------------------------------------------------
-- POLICY ADMINISTRATION PRIVILEGES
-- SECURITYADMIN owns the policy objects (CREATE MASKING POLICY on the schema)
-- and can attach them to tables it does NOT own (account-level APPLY MASKING
-- POLICY). This matters because dbt / TRANSFORMER_ROLE owns the data tables.
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
GRANT CREATE MASKING POLICY ON SCHEMA FOUNDATION_DB.MASKING TO ROLE SECURITYADMIN;
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE SECURITYADMIN;
-- TRANSFORMER_ROLE needs to apply the policies inside dbt post-hooks so that
-- masking is re-attached immediately whenever dbt rebuilds a table.
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE TRANSFORMER_ROLE;

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- POLICY: EMAIL MASKING
-- Full:    john.doe@example.com
-- Partial: j***.***@example.com
-- Masked:  ***MASKED***
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.EMAIL_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        -- Full access: admins, engineers, transformer
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
          OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
            THEN val

        -- Partial: analysts / data scientists see domain but obfuscated local part
        WHEN IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
          OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
            THEN REGEXP_REPLACE(val, '^(.).+(@.+)$', '\\1***\\2')

        -- Everyone else (PBI roles, unknown): fully masked
        ELSE '***@***.***'
    END;

-- ---------------------------------------------------------------------------
-- POLICY: PHONE NUMBER MASKING
-- Full:    +1-555-867-5309
-- Partial: +1-555-***-****
-- Masked:  ***-***-****
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.PHONE_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
          OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
            THEN val

        WHEN IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
          OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
            THEN REGEXP_REPLACE(val, '(\+?[\d\s-]*\d{3})[\d\s-]+(\d{4})$', '\\1-***-****')

        ELSE '***-***-****'
    END;

-- ---------------------------------------------------------------------------
-- POLICY: FULL NAME MASKING
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.NAME_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
          OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
            THEN val

        WHEN IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
          OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
            -- Show first initial + last name
            THEN UPPER(LEFT(val, 1)) || '***'

        ELSE '***'
    END;

-- ---------------------------------------------------------------------------
-- POLICY: DATE OF BIRTH — generalise to year only for partial access
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.DATE_OF_BIRTH_MASK AS (val DATE)
RETURNS DATE ->
    CASE
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
          OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
            THEN val

        -- Generalise: first day of birth year (preserves age for analytics)
        WHEN IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
          OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
            THEN DATE_FROM_PARTS(YEAR(val), 1, 1)

        ELSE NULL
    END;

-- ---------------------------------------------------------------------------
-- POLICY: NATIONAL ID / SSN — fully masked for all except admin
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.NATIONAL_ID_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        -- Engineers only (SYSADMIN / ACCOUNTADMIN inherit via hierarchy)
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
            THEN val

        -- Last 4 digits only for authorised analysts
        WHEN IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
            THEN '***-**-' || RIGHT(REGEXP_REPLACE(val, '[^0-9]', ''), 4)

        ELSE '***-**-****'
    END;

-- ---------------------------------------------------------------------------
-- POLICY: FINANCIAL / CARD NUMBER — PCI DSS compliant masking
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.CARD_NUMBER_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        -- Platform administrators only (ACCOUNTADMIN inherits SYSADMIN)
        WHEN IS_ROLE_IN_SESSION('SYSADMIN')
            THEN val

        -- Last 4 digits only (PCI DSS requirement)
        ELSE '****-****-****-' || RIGHT(REGEXP_REPLACE(val, '[^0-9]', ''), 4)
    END;

-- ---------------------------------------------------------------------------
-- POLICY: GENERIC STRING — catch-all for CONFIDENTIAL columns
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.CONFIDENTIAL_STRING_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
          OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
            THEN val
        ELSE '***CONFIDENTIAL***'
    END;

-- ---------------------------------------------------------------------------
-- POLICY: IP ADDRESS — GDPR treats IP addresses as personal data
-- Full:    203.0.113.42
-- Partial: 203.0.113.x  (subnet preserved for geo/network analytics)
-- Masked:  x.x.x.x
-- ---------------------------------------------------------------------------

CREATE OR REPLACE MASKING POLICY FOUNDATION_DB.MASKING.IP_ADDRESS_MASK AS (val STRING)
RETURNS STRING ->
    CASE
        WHEN IS_ROLE_IN_SESSION('DATA_ENGINEER_ROLE')
          OR IS_ROLE_IN_SESSION('TRANSFORMER_ROLE')
            THEN val

        -- Analysts keep the subnet (useful for bot/geo analysis), lose the host
        WHEN IS_ROLE_IN_SESSION('DATA_ANALYST_ROLE')
          OR IS_ROLE_IN_SESSION('DATA_SCIENTIST_ROLE')
            THEN REGEXP_REPLACE(val, '\\.\\d+$', '.x')

        ELSE 'x.x.x.x'
    END;

-- ---------------------------------------------------------------------------
-- APPLY privileges
-- SECURITYADMIN owns the policies (full privileges implicit) and holds the
-- account-level APPLY MASKING POLICY privilege granted above. Grant per-policy
-- APPLY to TRANSFORMER_ROLE so dbt post-hooks can re-attach masking whenever
-- a table is rebuilt.
-- ---------------------------------------------------------------------------

GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.EMAIL_MASK               TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.PHONE_MASK               TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.NAME_MASK                TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.DATE_OF_BIRTH_MASK       TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.NATIONAL_ID_MASK         TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.CARD_NUMBER_MASK         TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.CONFIDENTIAL_STRING_MASK TO ROLE TRANSFORMER_ROLE;
GRANT APPLY ON MASKING POLICY FOUNDATION_DB.MASKING.IP_ADDRESS_MASK          TO ROLE TRANSFORMER_ROLE;

-- ---------------------------------------------------------------------------
-- EXAMPLE POLICY APPLICATION
-- Apply to silver layer columns after table creation.
-- ---------------------------------------------------------------------------

-- ALTER TABLE FOUNDATION_DB.CUSTOMERS.CUSTOMERS
--     MODIFY COLUMN EMAIL_ADDRESS         SET MASKING POLICY FOUNDATION_DB.MASKING.EMAIL_MASK,
--                    PHONE_NUMBER         SET MASKING POLICY FOUNDATION_DB.MASKING.PHONE_MASK,
--                    FULL_NAME            SET MASKING POLICY FOUNDATION_DB.MASKING.NAME_MASK,
--                    DATE_OF_BIRTH        SET MASKING POLICY FOUNDATION_DB.MASKING.DATE_OF_BIRTH_MASK;

-- ---------------------------------------------------------------------------
-- VIEW: MASKING POLICY COVERAGE
-- Lists which columns have masking policies applied.
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_MASKING_POLICY_COVERAGE AS
SELECT
    pm.policy_name,
    pr.policy_kind,
    pr.ref_database_name,
    pr.ref_schema_name,
    pr.ref_entity_name   AS table_name,
    pr.ref_column_name   AS column_name,
    pm.created           AS policy_created
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES pr
JOIN SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES pm
    ON pm.policy_name = pr.policy_name
    AND pm.policy_schema = pr.policy_schema
    AND pm.policy_catalog = pr.policy_db
WHERE pr.policy_kind = 'MASKING_POLICY'
ORDER BY pr.ref_database_name, pr.ref_schema_name, pr.ref_entity_name, pr.ref_column_name;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_MASKING_POLICY_COVERAGE
    TO ROLE DATA_ENGINEER_ROLE;
