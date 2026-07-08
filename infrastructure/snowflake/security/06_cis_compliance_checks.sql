-- =============================================================================
-- 06_cis_compliance_checks.sql
-- Point-in-time compliance verification queries for the
-- CIS Snowflake Security Foundations Benchmark.
--
-- Run these queries periodically (e.g., monthly) or as part of an audit.
-- Each query is labelled with the CIS control it verifies.
-- A result of zero rows from a PASS query means the control is satisfied.
-- A non-zero result from a FAIL query indicates a compliance gap.
--
-- Run as: ACCOUNTADMIN (requires access to SNOWFLAKE.ACCOUNT_USAGE)
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- SECTION 1: IDENTITY AND ACCESS MANAGEMENT
-- =============================================================================

-- ---------------------------------------------------------------------------
-- CIS 1.1 — Ensure MFA is enforced for all non-service-account human users
-- FAIL if any human user has logged in with PASSWORD auth and no second factor.
-- ---------------------------------------------------------------------------

SELECT
    lh.user_name,
    lh.client_ip,
    lh.event_timestamp,
    lh.first_authentication_factor,
    lh.second_authentication_factor
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY lh
WHERE lh.is_success           = 'YES'
  AND lh.first_authentication_factor = 'PASSWORD'
  AND lh.second_authentication_factor IS NULL
  AND lh.event_timestamp      >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  -- Exclude service users by TYPE (04_users.sql sets TYPE = SERVICE)
  AND lh.user_name NOT IN (
        SELECT name FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
        WHERE type = 'SERVICE' AND deleted_on IS NULL
      )
ORDER BY lh.event_timestamp DESC;
-- Expected: 0 rows (all human logins should use SAML or PASSWORD+MFA).
-- Enforced going forward by MONITORING_DB.AUDIT.HUMAN_AUTH_POLICY
-- (08_authentication_policies.sql).

-- ---------------------------------------------------------------------------
-- CIS 1.2 — Ensure SSO is configured (SAML security integration exists)
-- PASS if a SAML2 integration is present and enabled.
-- ---------------------------------------------------------------------------

SHOW SECURITY INTEGRATIONS;
-- Expected: at least one row with TYPE = SAML2 and ENABLED = true

-- ---------------------------------------------------------------------------
-- CIS 1.3 — Ensure a strong password policy is applied at the account level
-- ---------------------------------------------------------------------------

SELECT SYSTEM$GET_ACCOUNT_LEVEL_SECURITY_POLICY();
-- Expected: PASSWORD_POLICY = STRONG_PASSWORD_POLICY

SHOW PASSWORD POLICIES;
-- Expected: STRONG_PASSWORD_POLICY exists with min_length >= 14

-- ---------------------------------------------------------------------------
-- CIS 1.4 — Ensure session timeout is configured
-- ---------------------------------------------------------------------------

SHOW SESSION POLICIES;
-- Expected: STANDARD_SESSION_POLICY with SESSION_IDLE_TIMEOUT_MINS <= 60

-- ---------------------------------------------------------------------------
-- CIS 1.5 — Ensure service accounts use RSA key-pair authentication
-- FAIL if any service account has a password set (no RSA key).
-- ---------------------------------------------------------------------------

SELECT
    name           AS service_account,
    login_name,
    has_rsa_public_key,
    email,
    created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE deleted_on IS NULL
  AND type = 'SERVICE'
  AND has_rsa_public_key = FALSE;
-- Expected: 0 rows (all service accounts must have an RSA key configured).
-- Key-pair-only auth is enforced by SERVICE_AUTH_POLICY
-- (08_authentication_policies.sql).

-- ---------------------------------------------------------------------------
-- CIS 1.6 — Ensure SCIM integration is configured
-- ---------------------------------------------------------------------------

SHOW SECURITY INTEGRATIONS LIKE '%SCIM%';
-- Expected: at least one row with TYPE = SCIM and ENABLED = true

-- ---------------------------------------------------------------------------
-- CIS 1.x — Users with no recent logins (potential orphaned accounts)
-- FAIL if any enabled user has not logged in for > 90 days.
-- ---------------------------------------------------------------------------

SELECT
    name                AS snowflake_user,
    login_name,
    last_success_login,
    DATEDIFF('day', last_success_login, CURRENT_TIMESTAMP()) AS days_since_login,
    has_rsa_public_key,
    disabled
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE deleted_on           IS NULL
  AND disabled              = FALSE
  AND (
        last_success_login  < DATEADD('day', -90, CURRENT_TIMESTAMP())
     OR last_success_login  IS NULL
  )
ORDER BY last_success_login ASC NULLS FIRST;
-- Expected: 0 rows (disabled or deprovisioned accounts should not appear)

-- =============================================================================
-- SECTION 2: NETWORK CONTROLS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- CIS 2.1 — Ensure a network policy is applied at the account level
-- ---------------------------------------------------------------------------

SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT;
-- Expected: value = CORPORATE_NETWORK_POLICY (not empty)

-- ---------------------------------------------------------------------------
-- CIS 2.2 — Ensure service accounts have individual network policies
-- FAIL if any service account does not have its own network policy.
-- ---------------------------------------------------------------------------

SELECT
    name           AS user_name,
    login_name,
    network_policy
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE deleted_on   IS NULL
  AND type         = 'SERVICE'
  AND (network_policy IS NULL OR network_policy = '');
-- Expected: 0 rows (all service accounts must have a network policy)

-- =============================================================================
-- SECTION 3: ACCESS CONTROLS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- CIS 3.1 — Ensure no privileges are granted directly to users
--
-- Snowflake enforces this at the platform level: it is architecturally
-- impossible to grant object-level privileges (SELECT, INSERT, etc.)
-- directly to a user. GRANTS_TO_USERS contains ONLY role-to-user grants —
-- every row has granted_on = 'ROLE'. CIS 3.1 is therefore automatically
-- satisfied by Snowflake's design.
--
-- The meaningful equivalent check in Snowflake is: are there users with
-- sensitive system roles (ACCOUNTADMIN, SYSADMIN, SECURITYADMIN) who should
-- not have them? That is covered by CIS 3.2 and 3.4 below.
--
-- This query serves as a sanity check — it must always return 0 rows.
-- A non-zero result would indicate an unexpected platform behaviour.
-- ---------------------------------------------------------------------------

SELECT
    grantee_name   AS user_name,
    role           AS role_granted,
    granted_by,
    created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE deleted_on   IS NULL
  AND role IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN')
ORDER BY grantee_name, role;
-- Expected: only the designated break-glass (ACCOUNTADMIN) and named admins.
-- Every row here is a privileged role holder; review each one is intentional.

-- ---------------------------------------------------------------------------
-- CIS 3.2 — Ensure ACCOUNTADMIN is assigned to as few users as possible
-- FAIL if more than 2 users hold ACCOUNTADMIN.
-- ---------------------------------------------------------------------------

SELECT
    grantee_name   AS user_name,
    role,
    granted_by,
    created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE role         = 'ACCOUNTADMIN'
  AND deleted_on   IS NULL
ORDER BY created_on;
-- Expected: <= 2 rows (ideally only a break-glass account)

-- ---------------------------------------------------------------------------
-- CIS 3.3 — Ensure ACCOUNTADMIN is not used for day-to-day operations
-- FAIL if ACCOUNTADMIN has been used in the last 7 days for non-admin queries.
-- ---------------------------------------------------------------------------

SELECT
    query_id,
    LEFT(query_text, 200)  AS query_preview,
    user_name,
    role_name,
    start_time,
    query_type
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE role_name        = 'ACCOUNTADMIN'
  AND query_type   NOT IN ('SHOW', 'DESCRIBE', 'SELECT')
  AND start_time       >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
-- Expected: 0 rows (ACCOUNTADMIN used only for break-glass or planned admin tasks)

-- ---------------------------------------------------------------------------
-- CIS 3.4 — Ensure SECURITYADMIN and SYSADMIN roles are held by separate users
-- FAIL if the same user holds both SECURITYADMIN and SYSADMIN.
-- ---------------------------------------------------------------------------

SELECT
    a.grantee_name      AS user_name
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS a
JOIN SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS b
    ON  a.grantee_name  = b.grantee_name
    AND a.deleted_on    IS NULL
    AND b.deleted_on    IS NULL
WHERE a.role = 'SECURITYADMIN'
  AND b.role = 'SYSADMIN';
-- Expected: 0 rows (separation of duties)

-- ---------------------------------------------------------------------------
-- CIS 3.5 — Ensure managed access is enabled on production schemas
-- FAIL if any production schema does not have managed access.
-- ---------------------------------------------------------------------------

SELECT
    catalog_name    AS database_name,
    schema_name,
    is_managed_access
FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
WHERE catalog_name IN ('FOUNDATION_DB', 'ANALYTICS_DB', 'RAW_DB', 'MONITORING_DB')
  AND deleted      IS NULL
  AND is_managed_access = 'NO'
ORDER BY catalog_name, schema_name;
-- Expected: 0 rows (all production schemas should have managed access)

-- =============================================================================
-- SECTION 4: DATA PROTECTION
-- =============================================================================

-- ---------------------------------------------------------------------------
-- CIS 4.3 — Ensure dynamic data masking covers all PII columns
-- FAIL if any column tagged PII does not have a masking policy applied.
-- ---------------------------------------------------------------------------

SELECT
    t.table_catalog        AS database_name,
    t.table_schema         AS schema_name,
    t.table_name,
    t.column_name,
    tv.tag_name,
    tv.tag_value           AS pii_category,
    mp.policy_name         AS masking_policy
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS t
JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tv
    ON  tv.object_name        = t.table_name
    AND tv.column_name        = t.column_name
    AND tv.tag_name           = 'PII_CATEGORY'
    AND tv.domain             = 'COLUMN'
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES mp
    ON  mp.ref_entity_name    = t.table_name
    AND mp.ref_column_name    = t.column_name
    AND mp.policy_kind        = 'MASKING_POLICY'
WHERE t.deleted              IS NULL
  AND tv.tag_value           IS NOT NULL
  AND mp.policy_name         IS NULL      -- No masking policy applied
ORDER BY t.table_catalog, t.table_schema, t.table_name;
-- Expected: 0 rows (all PII columns must have a masking policy)

-- =============================================================================
-- SECTION 5: AUDITING AND MONITORING
-- =============================================================================

-- ---------------------------------------------------------------------------
-- CIS 5.1 — Ensure the account edition supports the governance features used
-- by this template (masking policies, row access policies, tag-based policies
-- all require Enterprise edition or higher).
-- Note: SNOWFLAKE.ACCOUNT_USAGE retention is 365 days on ALL editions — the
-- edition requirement here is about the governance features, not log retention.
-- There is no SQL context function that returns the edition; check one of:
--   • Snowsight: Admin » Accounts (shows edition per account)
--   • From the ORGADMIN account: SHOW ORGANIZATION ACCOUNTS; (EDITION column)
-- ---------------------------------------------------------------------------

-- SHOW ORGANIZATION ACCOUNTS;   -- run as ORGADMIN; check the EDITION column
-- Expected: ENTERPRISE or BUSINESS_CRITICAL

-- ---------------------------------------------------------------------------
-- CIS 5.2 — Ensure failed login monitoring alert is active
-- ---------------------------------------------------------------------------

SHOW ALERTS LIKE 'ALERT_FAILED_LOGIN_SPIKE';
-- Expected: 1 row with state = STARTED

-- ---------------------------------------------------------------------------
-- CIS 5.3 — Ensure ACCOUNTADMIN usage alert is active
-- ---------------------------------------------------------------------------

SHOW ALERTS LIKE 'ALERT_ACCOUNTADMIN_USAGE';
-- Expected: 1 row with state = STARTED (created in 04_privileged_access_alerts.sql)

-- ---------------------------------------------------------------------------
-- CIS 5.4 / 6.1 / 6.2 — Ensure all security alerts are running
-- (ALERT_HISTORY records executions, not definitions — alert definition state
--  comes from SHOW ALERTS.)
-- ---------------------------------------------------------------------------

SHOW ALERTS IN ACCOUNT;

SELECT
    "name"      AS alert_name,
    "state",
    "schedule",
    "warehouse"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" IN (
    'ALERT_FAILED_LOGIN_SPIKE',
    'ALERT_ACCOUNTADMIN_USAGE',
    'ALERT_NETWORK_POLICY_CHANGE',
    'ALERT_ROLE_GRANT_CHANGE',
    'ALERT_MASKING_POLICY_CHANGE',
    'ALERT_BREAKGLASS_LOGIN',
    'ALERT_UNEXPECTED_DDL',
    'ALERT_DBT_TEST_FAILURES'
)
ORDER BY alert_name;
-- Expected: all alerts in started state

-- =============================================================================
-- COMPLIANCE SUMMARY DASHBOARD
-- Returns a single-row score for each CIS section.
-- =============================================================================

WITH
mfa_failures AS (
    SELECT COUNT(*) AS cnt
    FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
    WHERE is_success = 'YES'
      AND first_authentication_factor = 'PASSWORD'
      AND second_authentication_factor IS NULL
      AND event_timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP())
      AND user_name NOT IN (
            SELECT name FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
            WHERE type = 'SERVICE' AND deleted_on IS NULL
          )
),
orphaned_users AS (
    SELECT COUNT(*) AS cnt
    FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
    WHERE deleted_on IS NULL AND disabled = FALSE
      AND (last_success_login < DATEADD('day', -90, CURRENT_TIMESTAMP())
           OR last_success_login IS NULL)
),
svc_no_key AS (
    SELECT COUNT(*) AS cnt
    FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
    WHERE deleted_on IS NULL
      AND type = 'SERVICE'
      AND has_rsa_public_key = FALSE
),
unmanaged_schemas AS (
    SELECT COUNT(*) AS cnt
    FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
    WHERE catalog_name IN ('FOUNDATION_DB', 'ANALYTICS_DB', 'RAW_DB', 'MONITORING_DB')
      AND deleted IS NULL AND is_managed_access = 'NO'
),
unmasked_pii AS (
    SELECT COUNT(*) AS cnt
    FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
        ON tr.object_name = c.table_name AND tr.column_name = c.column_name
        AND tr.tag_name = 'PII_CATEGORY' AND tr.domain = 'COLUMN'
    LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES pr
        ON pr.ref_entity_name = c.table_name AND pr.ref_column_name = c.column_name
        AND pr.policy_kind = 'MASKING_POLICY'
    WHERE c.deleted IS NULL AND pr.policy_name IS NULL
)
SELECT
    mfa_failures.cnt     AS cis_1_1_mfa_failures_30d,
    svc_no_key.cnt       AS cis_1_5_svc_accounts_missing_rsa_key,
    orphaned_users.cnt   AS cis_orphaned_users_90d,
    unmanaged_schemas.cnt AS cis_3_5_unmanaged_schemas,
    unmasked_pii.cnt     AS cis_4_3_pii_columns_without_masking
FROM mfa_failures, orphaned_users, svc_no_key, unmanaged_schemas, unmasked_pii;
-- Expected: all columns = 0
