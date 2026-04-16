-- =============================================================================
-- 07_scim_integration.sql
-- Configures SCIM (System for Cross-domain Identity Management) to automate
-- user lifecycle management from Azure Active Directory.
--
-- CIS Snowflake Foundations Benchmark controls addressed:
--   CIS 1.6 — Ensure SCIM is used for automated user provisioning/deprovisioning
--
-- Why this matters:
--   Manual user creation is error-prone and slow to deprovision leavers.
--   SCIM ensures that when an employee leaves, their Azure AD account disable
--   automatically propagates to Snowflake, eliminating orphaned access.
--
-- Prerequisites:
--   1. Azure AD Enterprise Application created for Snowflake (separate from the
--      SAML app in powerbi/saml_oauth_setup.md — use the Snowflake gallery app
--      for provisioning or configure a custom SCIM app).
--   2. USERADMIN role in Snowflake to allow SCIM to create/update/deactivate users.
--
-- Run as: ACCOUNTADMIN
--
-- GOVERNMENT / PUBLIC SECTOR NOTES
-- ---------------------------------
-- • For FedRAMP or DoD environments, use a FedRAMP-authorized IdP:
--     - Azure AD Government (GCC High) — SCIM_CLIENT = 'AZURE' still applies;
--       the SCIM endpoint targets snowflakecomputing.mil not .com.
--     - Okta (FedRAMP Moderate authorized) — use SCIM_CLIENT = 'OKTA'.
--     - Ping Identity (FedRAMP authorized) — use SCIM_CLIENT = 'GENERIC'.
-- • Commercial Azure AD (azure.com) is NOT FedRAMP High authorized.
--   Federal agencies operating at IL4+ MUST use Azure Government or another
--   FedRAMP High IdP for provisioning into their snowflakecomputing.mil account.
-- • CAC/PIV card authentication is handled at the IdP layer, not by Snowflake.
--   Configure the upstream IdP to accept CAC/PIV, then federate into Snowflake
--   via the SAML2 security integration (saml_oauth_setup.md). SCIM still handles
--   user provisioning; authentication uses the IdP's CAC/PIV assertion.
-- • SCIM token rotation every 90 days is a common government requirement.
--   Automate token rotation via a secrets manager (HashiCorp Vault or AWS
--   Secrets Manager GovCloud) with a Lambda/Function App that calls
--   SYSTEM$GENERATE_SCIM_ACCESS_TOKEN and updates the IdP configuration.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- SCIM SECURITY INTEGRATION
-- Creates a SCIM endpoint in Snowflake that Azure AD will push user/group
-- changes to.
-- ---------------------------------------------------------------------------

CREATE SECURITY INTEGRATION IF NOT EXISTS AZURE_AD_SCIM
    TYPE                = SCIM
    SCIM_CLIENT         = 'AZURE'
    RUN_AS_ROLE         = 'USERADMIN'    -- SCIM operations execute as USERADMIN
    SYNC_PASSWORD       = FALSE           -- Do not sync passwords; auth via SAML/OAuth
    COMMENT             = 'CIS 1.6: Azure AD SCIM provisioning integration.';

-- ---------------------------------------------------------------------------
-- GENERATE BEARER TOKEN FOR AZURE AD
-- Run this command ONCE and copy the token value into the Azure AD Enterprise
-- Application provisioning configuration (Secret Token field).
-- The token is rotated using SYSTEM$GENERATE_SCIM_ACCESS_TOKEN whenever needed.
-- ---------------------------------------------------------------------------

-- SELECT SYSTEM$GENERATE_SCIM_ACCESS_TOKEN('AZURE_AD_SCIM') AS scim_token;

-- ---------------------------------------------------------------------------
-- RETRIEVE SCIM ENDPOINT URL
-- Copy this URL into the Azure AD Enterprise App provisioning "Tenant URL" field.
-- Format: https://<account_identifier>.snowflakecomputing.com/scim/v2/
-- ---------------------------------------------------------------------------

-- DESCRIBE SECURITY INTEGRATION AZURE_AD_SCIM;
-- SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('AZURE_AD_SCIM');

-- ---------------------------------------------------------------------------
-- AZURE AD CONFIGURATION STEPS  (performed in Azure Portal)
-- ---------------------------------------------------------------------------
-- 1. In Azure AD > Enterprise Applications, find the Snowflake app.
-- 2. Navigate to Provisioning > Configure provisioning.
-- 3. Set Provisioning Mode = Automatic.
-- 4. Enter Tenant URL: https://<your-account>.snowflakecomputing.com/scim/v2/
-- 5. Enter Secret Token: (output of SYSTEM$GENERATE_SCIM_ACCESS_TOKEN above).
-- 6. Test Connection, then Save.
-- 7. Under Mappings, ensure:
--      - User provisioning is enabled (maps AD attributes to Snowflake user)
--      - Group provisioning is enabled (maps AD groups to Snowflake roles)
-- 8. Under Settings:
--      - Scope: "Sync only assigned users and groups" (least-privilege)
--      - Provisioning Status: On
-- 9. Assign the AD groups that map to Snowflake roles:
--      AD Group                → Snowflake Role
--      SF_DATA_ENGINEERS       → DATA_ENGINEER_ROLE
--      SF_DATA_ANALYSTS        → DATA_ANALYST_ROLE
--      SF_DATA_SCIENTISTS      → DATA_SCIENTIST_ROLE
--      PBI_MARKETING           → POWERBI_MARKETING_ROLE
--      PBI_FINANCE             → POWERBI_FINANCE_ROLE
--      PBI_OPERATIONS          → POWERBI_OPERATIONS_ROLE

-- ---------------------------------------------------------------------------
-- SCIM ATTRIBUTE MAPPING NOTES
-- ---------------------------------------------------------------------------
-- Snowflake expects these attributes from the SCIM provisioner:
--   userName        → Snowflake LOGIN_NAME (typically email or UPN)
--   displayName     → DISPLAY_NAME
--   emails[0].value → EMAIL
--   active          → when FALSE, disables the Snowflake user immediately
--
-- Role assignment is controlled via group membership in Azure AD.
-- Map AD group → Snowflake role inside the SAML claims (see saml_oauth_setup.md).

-- ---------------------------------------------------------------------------
-- AUDIT VIEW: SCIM-MANAGED USERS
-- Identify which users were provisioned via SCIM vs created manually.
-- Users created manually are a risk — they may not be in Azure AD lifecycle.
-- ---------------------------------------------------------------------------

USE DATABASE MONITORING_DB;
USE SCHEMA AUDIT;

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_SCIM_VS_MANUAL_USERS AS
SELECT
    u.name                          AS snowflake_user,
    u.login_name,
    u.email,
    u.created_on,
    u.last_success_login,
    u.disabled,
    u.has_rsa_public_key,
    CASE
        WHEN u.owner = 'USERADMIN'
             AND u.created_on > DATEADD('month', -6, CURRENT_TIMESTAMP())
             THEN 'LIKELY_SCIM'    -- Recently created by USERADMIN = probably SCIM
        WHEN u.has_rsa_public_key  THEN 'SERVICE_ACCOUNT'
        ELSE 'MANUAL_OR_LEGACY'
    END                             AS provisioning_method
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS u
WHERE u.deleted_on IS NULL
ORDER BY u.created_on DESC;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_SCIM_VS_MANUAL_USERS
    TO ROLE DATA_ENGINEER_ROLE;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SHOW SECURITY INTEGRATIONS LIKE 'AZURE_AD_SCIM';
-- DESCRIBE SECURITY INTEGRATION AZURE_AD_SCIM;
