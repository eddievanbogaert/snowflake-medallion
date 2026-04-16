-- =============================================================================
-- 06_password_policies.sql
-- Enforces strong password and session timeout requirements.
--
-- CIS Snowflake Foundations Benchmark controls addressed:
--   CIS 1.3 — Ensure a strong password policy is configured
--   CIS 1.4 — Ensure account-level session timeout is configured
--
-- Note: Password policies apply to Snowflake-native password auth only.
-- SSO users (Azure AD SAML) inherit password and MFA policy from Azure AD;
-- those users do not need a Snowflake password policy, but the account-level
-- policy acts as a safety net for any local accounts that may exist.
--
-- Run as: ACCOUNTADMIN
--
-- GOVERNMENT / PUBLIC SECTOR NOTES
-- ---------------------------------
-- • FedRAMP High and DoD IL4/IL5 environments should enforce the NIST SP 800-63B
--   Digital Identity Guidelines, which recommend: >= 15 characters, no mandatory
--   complexity rules (but ban known compromised passwords), 365-day max age.
--   Adjust PASSWORD_MAX_AGE_DAYS and PASSWORD_MIN_LENGTH accordingly.
-- • NIST 800-63B also discourages frequent forced rotation (it encourages rotation
--   only on evidence of compromise). However, most government agency security
--   policies still mandate 90-day rotation — align with your agency's SSP.
-- • For PIV/CAC card authentication (common in federal environments), Snowflake
--   does not natively support PIV/CAC. Use a SAML2 IdP (e.g., Azure AD GCC High,
--   Okta FedRAMP) that accepts PIV/CAC as the upstream authenticator, then
--   configure the SAML2 security integration in Snowflake.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- PASSWORD POLICY  (CIS 1.3)
-- Applies to Snowflake-native password authentication.
-- Service accounts use RSA key-pair auth and are unaffected by this policy
-- at login time, but the policy protects their stored password hash if one
-- is accidentally set.
-- ---------------------------------------------------------------------------

CREATE PASSWORD POLICY IF NOT EXISTS STRONG_PASSWORD_POLICY
    PASSWORD_MIN_LENGTH          = 14       -- CIS recommends >= 14 characters
    PASSWORD_MAX_LENGTH          = 256
    PASSWORD_MIN_UPPER_CASE_CHARS = 1
    PASSWORD_MIN_LOWER_CASE_CHARS = 1
    PASSWORD_MIN_NUMERIC_CHARS   = 1
    PASSWORD_MIN_SPECIAL_CHARS   = 1
    PASSWORD_MIN_AGE_DAYS        = 1        -- Prevent immediate password reuse
    PASSWORD_MAX_AGE_DAYS        = 90       -- Force rotation every 90 days
    PASSWORD_MAX_RETRIES         = 5        -- Lock after 5 consecutive failures
    PASSWORD_LOCKOUT_TIME_MINS   = 30       -- Lockout duration
    PASSWORD_HISTORY             = 24       -- Cannot reuse last 24 passwords
    COMMENT = 'CIS 1.3: Strong password policy. Applies to native auth accounts.';

-- ---------------------------------------------------------------------------
-- SESSION POLICY  (CIS 1.4)
-- Limits exposure from abandoned sessions (e.g. a left-open Snowsight tab
-- or a long-idle SnowSQL connection).
-- ---------------------------------------------------------------------------

CREATE SESSION POLICY IF NOT EXISTS STANDARD_SESSION_POLICY
    SESSION_IDLE_TIMEOUT_MINS    = 60       -- Terminate idle sessions after 60 min
    SESSION_UI_IDLE_TIMEOUT_MINS = 30       -- Shorter timeout for Snowsight browser sessions
    -- ALLOWED_SECONDARY_ROLES default is ALL, which lets users activate any granted
    -- role as a secondary role in a session — broadening their effective permissions.
    -- For strict least-privilege: set BLOCKED_SECONDARY_ROLES = ('ALL') so users
    -- can only use their explicitly set primary role per session.
    -- BLOCKED_SECONDARY_ROLES = ('ALL')   -- uncomment to enforce strict single-role sessions
    COMMENT = 'CIS 1.4: Session idle timeout. Reduces exposure from abandoned sessions.';

-- Stricter policy for privileged users (applied per-user in 04_users.sql)
CREATE SESSION POLICY IF NOT EXISTS PRIVILEGED_SESSION_POLICY
    SESSION_IDLE_TIMEOUT_MINS    = 30
    SESSION_UI_IDLE_TIMEOUT_MINS = 15
    -- Privileged users must operate in a single explicitly chosen role; no secondary roles.
    BLOCKED_SECONDARY_ROLES      = ('ALL')
    COMMENT = 'CIS 1.4: Shorter session timeout + no secondary roles for privileged/admin users.';

-- ---------------------------------------------------------------------------
-- APPLY POLICIES AT ACCOUNT LEVEL
-- The account-level assignment acts as the default for any user that does
-- not have a user-level override.
-- ---------------------------------------------------------------------------

ALTER ACCOUNT SET PASSWORD POLICY STRONG_PASSWORD_POLICY;
ALTER ACCOUNT SET SESSION POLICY STANDARD_SESSION_POLICY;

-- Apply stricter session timeout to ACCOUNTADMIN users (set in 04_users.sql)
-- Example — uncomment and replace with actual admin user names:
-- ALTER USER ADMIN_BREAKGLASS SET SESSION POLICY = PRIVILEGED_SESSION_POLICY;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SHOW PASSWORD POLICIES;
-- SHOW SESSION POLICIES;
-- SELECT SYSTEM$GET_ACCOUNT_LEVEL_SECURITY_POLICY();
