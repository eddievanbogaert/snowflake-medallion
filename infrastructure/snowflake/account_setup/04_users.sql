-- =============================================================================
-- 04_users.sql
-- Creates service accounts and configures user settings.
--
-- IMPORTANT: This file contains TEMPLATES only.
-- Passwords and RSA public keys must be supplied from your secrets manager
-- (e.g. AWS Secrets Manager, Azure Key Vault, HashiCorp Vault).
-- Never hardcode credentials in this file.
--
-- Recommended auth for service accounts: RSA key-pair (no password).
-- Recommended auth for human users: SAML/SSO via Azure AD (no Snowflake password).
--
-- Run as: USERADMIN (or SECURITYADMIN)
-- =============================================================================

USE ROLE USERADMIN;

-- ---------------------------------------------------------------------------
-- SERVICE ACCOUNT: Data Loader (Fivetran / ADF / Snowpipe)
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS SVC_LOADER
    TYPE                 = SERVICE
    LOGIN_NAME           = 'SVC_LOADER'
    DISPLAY_NAME         = 'Service Account — Data Loader'
    DEFAULT_ROLE         = LOADER_ROLE
    DEFAULT_WAREHOUSE    = INGESTION_WH
    DEFAULT_NAMESPACE    = 'RAW_DB'
    MUST_CHANGE_PASSWORD = FALSE
    -- RSA_PUBLIC_KEY populated from secrets manager during bootstrap
    -- RSA_PUBLIC_KEY = '<paste_public_key_here>'
    COMMENT              = 'Fivetran / ADF / Snowpipe ingestion service account. Key-pair auth only.';

GRANT ROLE LOADER_ROLE TO USER SVC_LOADER;

-- ---------------------------------------------------------------------------
-- SERVICE ACCOUNT: dbt Transformer
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS SVC_DBT_TRANSFORMER
    TYPE                 = SERVICE
    LOGIN_NAME           = 'SVC_DBT_TRANSFORMER'
    DISPLAY_NAME         = 'Service Account — dbt Transformer'
    DEFAULT_ROLE         = TRANSFORMER_ROLE
    DEFAULT_WAREHOUSE    = TRANSFORM_WH
    DEFAULT_NAMESPACE    = 'FOUNDATION_DB'
    MUST_CHANGE_PASSWORD = FALSE
    -- RSA_PUBLIC_KEY = '<paste_public_key_here>'
    COMMENT              = 'dbt transformation service account. Key-pair auth only.';

GRANT ROLE TRANSFORMER_ROLE TO USER SVC_DBT_TRANSFORMER;

-- ---------------------------------------------------------------------------
-- SERVICE ACCOUNT: Power BI Gateway
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS SVC_POWERBI
    TYPE                 = SERVICE
    LOGIN_NAME           = 'SVC_POWERBI'
    DISPLAY_NAME         = 'Service Account — Power BI Gateway'
    DEFAULT_ROLE         = POWERBI_ROLE
    DEFAULT_WAREHOUSE    = ANALYTICS_WH
    DEFAULT_NAMESPACE    = 'ANALYTICS_DB'
    MUST_CHANGE_PASSWORD = FALSE
    -- RSA_PUBLIC_KEY = '<paste_public_key_here>'
    COMMENT              = 'Power BI on-premise gateway service account. Key-pair auth only.';

GRANT ROLE POWERBI_ROLE TO USER SVC_POWERBI;

-- ---------------------------------------------------------------------------
-- HUMAN USERS (examples — in practice, provision via IDP SCIM or SAML JIT)
-- Human users should authenticate via Azure AD SAML SSO.
-- Do NOT set a Snowflake password for users that authenticate via SSO.
-- ---------------------------------------------------------------------------

-- Template: Data Engineer
-- CREATE USER IF NOT EXISTS <first>.<last>@mycompany.com
--     LOGIN_NAME           = '<first>.<last>@mycompany.com'
--     DISPLAY_NAME         = '<First Last>'
--     DEFAULT_ROLE         = DATA_ENGINEER_ROLE
--     DEFAULT_WAREHOUSE    = ADMIN_WH
--     DEFAULT_NAMESPACE    = 'FOUNDATION_DB'
--     MUST_CHANGE_PASSWORD = FALSE   -- SSO; no Snowflake password
--     COMMENT              = 'Data engineer — provisioned via Azure AD SAML';
-- GRANT ROLE DATA_ENGINEER_ROLE TO USER <first>.<last>@mycompany.com;

-- Template: Data Analyst
-- CREATE USER IF NOT EXISTS <first>.<last>@mycompany.com
--     LOGIN_NAME           = '<first>.<last>@mycompany.com'
--     DISPLAY_NAME         = '<First Last>'
--     DEFAULT_ROLE         = DATA_ANALYST_ROLE
--     DEFAULT_WAREHOUSE    = ANALYTICS_WH
--     DEFAULT_NAMESPACE    = 'ANALYTICS_DB'
--     MUST_CHANGE_PASSWORD = FALSE
--     COMMENT              = 'Data analyst — provisioned via Azure AD SAML';
-- GRANT ROLE DATA_ANALYST_ROLE TO USER <first>.<last>@mycompany.com;

-- ---------------------------------------------------------------------------
-- EMERGENCY BREAK-GLASS ACCOUNT (template)
-- The only human-usable account that holds ACCOUNTADMIN. Native password +
-- MFA (no SSO dependency) so the platform stays administrable during an IdP
-- outage. Referenced by ALERT_BREAKGLASS_LOGIN
-- (monitoring/04_privileged_access_alerts.sql) — every login alerts the
-- security team and must map to a change ticket.
-- ---------------------------------------------------------------------------

-- CREATE USER IF NOT EXISTS ADMIN_BREAKGLASS
--     LOGIN_NAME           = 'ADMIN_BREAKGLASS'
--     DISPLAY_NAME         = 'Emergency Break-Glass Administrator'
--     PASSWORD             = '<from-secrets-manager-sealed-envelope>'
--     MUST_CHANGE_PASSWORD = TRUE
--     DEFAULT_ROLE         = ACCOUNTADMIN
--     DEFAULT_WAREHOUSE    = ADMIN_WH
--     COMMENT              = 'Break-glass ACCOUNTADMIN. Password sealed in secrets manager; every login alerts security.';
-- GRANT ROLE ACCOUNTADMIN TO USER ADMIN_BREAKGLASS;
-- After first login: enrol MFA immediately, then apply the strict session policy:
-- ALTER USER ADMIN_BREAKGLASS SET SESSION POLICY PRIVILEGED_SESSION_POLICY;

-- ---------------------------------------------------------------------------
-- PASSWORD AND SESSION POLICIES
-- Defined once, in 06_password_policies.sql (STRONG_PASSWORD_POLICY,
-- STANDARD_SESSION_POLICY, PRIVILEGED_SESSION_POLICY) and applied at the
-- account level there. Do not define per-user policy objects here — a single
-- authoritative set keeps the CIS 1.3/1.4 evidence trail simple.
-- ---------------------------------------------------------------------------
