-- =============================================================================
-- 08_authentication_policies.sql
-- Authentication policies pin WHICH authentication methods each population of
-- users may use — the modern control behind Snowflake's platform-wide MFA
-- enforcement (and the control the Trust Center's Security Essentials scanner
-- checks for).
--
-- Populations:
--   • Humans        → SAML SSO only. No Snowflake passwords to phish, rotate,
--                     or leak; MFA is enforced upstream by the IdP.
--   • Service users → key-pair only. Blocks password/UI logins outright even
--                     if a password were accidentally set.
--   • Break-glass   → password + enforced MFA enrolment, restricted to the UI.
--                     Exists so the platform stays administrable during an IdP
--                     outage.
--
-- CIS Snowflake Foundations Benchmark: strengthens the MFA/SSO controls in
-- Section 1 (see docs/architecture/cis_benchmark_compliance.md).
--
-- Run as: ACCOUNTADMIN
-- Prerequisites: 04_users.sql (users), 07_scim_integration.sql + SAML
--                integration (powerbi/saml_oauth_setup.md) before applying the
--                account-level human policy.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Authentication policies are schema-level objects; keep them with the other
-- governance objects.
CREATE AUTHENTICATION POLICY IF NOT EXISTS MONITORING_DB.AUDIT.HUMAN_AUTH_POLICY
    AUTHENTICATION_METHODS = ('SAML')
    COMMENT = 'Humans authenticate via Azure AD SAML SSO only. MFA enforced by the IdP.';

CREATE AUTHENTICATION POLICY IF NOT EXISTS MONITORING_DB.AUDIT.SERVICE_AUTH_POLICY
    AUTHENTICATION_METHODS = ('KEYPAIR')
    COMMENT = 'Service accounts authenticate with RSA key pairs only. No passwords, no UI.';

CREATE AUTHENTICATION POLICY IF NOT EXISTS MONITORING_DB.AUDIT.BREAKGLASS_AUTH_POLICY
    AUTHENTICATION_METHODS     = ('PASSWORD')
    MFA_ENROLLMENT             = REQUIRED
    MFA_AUTHENTICATION_METHODS = ('PASSWORD')
    CLIENT_TYPES               = ('SNOWFLAKE_UI')
    COMMENT = 'Break-glass admin: native password + mandatory MFA, Snowsight only.';

-- ---------------------------------------------------------------------------
-- APPLY: service accounts (safe to run immediately)
-- ---------------------------------------------------------------------------

ALTER USER SVC_LOADER          SET AUTHENTICATION POLICY MONITORING_DB.AUDIT.SERVICE_AUTH_POLICY;
ALTER USER SVC_DBT_TRANSFORMER SET AUTHENTICATION POLICY MONITORING_DB.AUDIT.SERVICE_AUTH_POLICY;
ALTER USER SVC_POWERBI         SET AUTHENTICATION POLICY MONITORING_DB.AUDIT.SERVICE_AUTH_POLICY;

-- ---------------------------------------------------------------------------
-- APPLY: break-glass (uncomment once the user exists — see 04_users.sql)
-- ---------------------------------------------------------------------------

-- ALTER USER ADMIN_BREAKGLASS SET AUTHENTICATION POLICY MONITORING_DB.AUDIT.BREAKGLASS_AUTH_POLICY;

-- ---------------------------------------------------------------------------
-- APPLY: account level (humans)
-- The account-level policy is the default for every user without a user-level
-- override. Apply ONLY after confirming:
--   1. SAML SSO works for at least one admin-capable human user, AND
--   2. the break-glass user carries BREAKGLASS_AUTH_POLICY (its user-level
--      policy overrides this account default — otherwise you lock out your
--      recovery path).
-- ---------------------------------------------------------------------------

-- ALTER ACCOUNT SET AUTHENTICATION POLICY MONITORING_DB.AUDIT.HUMAN_AUTH_POLICY;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SHOW AUTHENTICATION POLICIES;
-- SELECT SYSTEM$GET_ACCOUNT_LEVEL_SECURITY_POLICY();
-- Per-user assignments:
-- SELECT * FROM TABLE(MONITORING_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
--     POLICY_NAME => 'MONITORING_DB.AUDIT.SERVICE_AUTH_POLICY'));
