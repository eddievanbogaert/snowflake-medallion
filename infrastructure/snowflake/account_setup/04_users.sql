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
-- PASSWORD POLICY
-- Enforce strong passwords and MFA for any user with a Snowflake password.
-- ---------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- Create a password policy (Snowflake Business Critical / Enterprise feature)
CREATE PASSWORD POLICY IF NOT EXISTS CORPORATE_PASSWORD_POLICY
    PASSWORD_MIN_LENGTH             = 16
    PASSWORD_MAX_LENGTH             = 256
    PASSWORD_MIN_UPPER_CASE_CHARS   = 2
    PASSWORD_MIN_LOWER_CASE_CHARS   = 2
    PASSWORD_MIN_NUMERIC_CHARS      = 2
    PASSWORD_MIN_SPECIAL_CHARS      = 2
    PASSWORD_MAX_AGE_DAYS           = 90
    PASSWORD_MAX_RETRIES            = 5
    PASSWORD_LOCKOUT_TIME_MINS      = 30
    COMMENT                         = 'Corporate password policy — applies to any Snowflake-native password auth.';

-- Apply password policy at the account level
-- ALTER ACCOUNT SET PASSWORD POLICY CORPORATE_PASSWORD_POLICY;

-- ---------------------------------------------------------------------------
-- SESSION POLICIES
-- Enforce session timeout and MFA.
-- ---------------------------------------------------------------------------

CREATE SESSION POLICY IF NOT EXISTS CORPORATE_SESSION_POLICY
    SESSION_IDLE_TIMEOUT_MINS         = 240   -- 4 hours idle
    SESSION_UI_IDLE_TIMEOUT_MINS      = 60    -- 1 hour idle in Snowsight
    COMMENT                           = 'Corporate session policy — idle timeout enforcement.';

-- Apply session policy at account level
-- ALTER ACCOUNT SET SESSION POLICY CORPORATE_SESSION_POLICY;

-- Apply tighter session policy to service accounts (they should use short-lived tokens)
-- ALTER USER SVC_LOADER SET SESSION POLICY CORPORATE_SESSION_POLICY;
