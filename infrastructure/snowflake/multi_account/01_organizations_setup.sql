-- =============================================================================
-- multi_account/01_organizations_setup.sql
-- Snowflake Organizations — central governance across multiple accounts.
--
-- OVERVIEW
-- --------
-- A Snowflake Organization is an optional top-level construct that groups
-- multiple Snowflake accounts under a single billing and governance umbrella.
-- Key capabilities it unlocks:
--
--   • Centralised usage and cost reporting across all accounts
--   • Account-level budgets enforced via Snowflake's ORGADMIN role
--   • Cross-account data sharing without external network hops
--   • Replication groups for HA/DR (see 03_account_replication.sql)
--   • Consistent account-level security policy via ORGADMIN
--
-- RECOMMENDED ACCOUNT TOPOLOGY
-- -----------------------------
-- This template assumes the most common pattern for mid-to-large organisations:
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │  SNOWFLAKE ORGANIZATION  (ORGADMIN — single billing + governance)  │
--   └─────┬───────────────┬──────────────────┬────────────────────┘
--         │               │                  │
--    ┌────▼────┐    ┌─────▼─────┐    ┌──────▼──────┐
--    │  DEV    │    │  STAGING  │    │    PROD     │
--    │ account │    │  account  │    │   account   │
--    └─────────┘    └───────────┘    └─────────────┘
--
-- Alternatively, for orgs that need strict BU isolation:
--
--   ORG ── PROD_FINANCE ── PROD_MARKETING ── PROD_OPERATIONS ── SHARED_SERVICES
--
-- See docs/architecture/multi_account_architecture.md for guidance on
-- choosing the right topology.
--
-- PREREQUISITES
-- -------------
--   • Snowflake Business Critical edition (required for Replication Groups)
--   • Every Snowflake account belongs to an organization; enable the ORGADMIN
--     role on your primary account (Snowsight: Admin » Accounts, or ask the
--     account team for legacy accounts) to manage it
--   • Run these commands from the account where ORGADMIN is enabled
--
-- Run as: ORGADMIN (on the designated governance/admin account)
-- =============================================================================

USE ROLE ORGADMIN;

-- ---------------------------------------------------------------------------
-- VIEW CURRENT ORGANISATION AND ACCOUNTS
-- ---------------------------------------------------------------------------

SHOW ORGANIZATION ACCOUNTS;
-- Lists all accounts in the organisation with region, edition, and status.

SHOW REPLICATION ACCOUNTS;
-- Lists accounts that have replication enabled.

-- ---------------------------------------------------------------------------
-- CREATE ACCOUNTS
-- Run these commands from the ORGADMIN-enabled account to provision new accounts.
-- Replace placeholder values with your actual org name, region, and edition.
--
-- REGION format: use Snowflake region IDs (lowercase), NOT cloud provider codes.
--   Examples: aws_us_east_1, aws_eu_west_1, azure_eastus, gcp_us_central1
--   Full list: https://docs.snowflake.com/en/user-guide/admin-account-identifier#region-ids
--
-- GOVERNMENT CLOUD regions (FedRAMP):
--   aws_us_gov_virginia   (AWS GovCloud East — FedRAMP High)
--   azure_usgoviowa       (Azure Government Iowa)
--   azure_usgovvirginia   (Azure Government Virginia)
--   Accounts in these regions are on snowflakecomputing.mil, not .com
--
-- MUST_CHANGE_PASSWORD should be TRUE for any account bootstrapped with a
-- temporary password. This forces the admin to set a permanent password on
-- first login, preventing use of a known/shared bootstrap password.
-- ---------------------------------------------------------------------------

-- Development account
-- CREATE ACCOUNT <YOUR_ORG>_DEV
--     ADMIN_NAME            = 'ORGADMIN_SVC'
--     ADMIN_PASSWORD        = '<use-a-strong-temporary-password>'
--     MUST_CHANGE_PASSWORD  = TRUE               -- force password reset on first login
--     EMAIL                 = 'snowflake-admin@mycompany.com'
--     EDITION               = 'ENTERPRISE'
--     REGION                = 'aws_us_east_1'    -- lowercase Snowflake region ID
--     COMMENT               = 'Development and experimentation account';

-- Staging / pre-production account
-- CREATE ACCOUNT <YOUR_ORG>_STAGING
--     ADMIN_NAME            = 'ORGADMIN_SVC'
--     ADMIN_PASSWORD        = '<use-a-strong-temporary-password>'
--     MUST_CHANGE_PASSWORD  = TRUE
--     EMAIL                 = 'snowflake-admin@mycompany.com'
--     EDITION               = 'ENTERPRISE'
--     REGION                = 'aws_us_east_1'
--     COMMENT               = 'Staging environment for pre-production validation';

-- Production account
-- CREATE ACCOUNT <YOUR_ORG>_PROD
--     ADMIN_NAME            = 'ORGADMIN_SVC'
--     ADMIN_PASSWORD        = '<use-a-strong-temporary-password>'
--     MUST_CHANGE_PASSWORD  = TRUE
--     EMAIL                 = 'snowflake-admin@mycompany.com'
--     EDITION               = 'BUSINESS_CRITICAL'  -- required for Failover Groups
--     REGION                = 'aws_us_east_1'
--     COMMENT               = 'Production data platform';

-- ---------------------------------------------------------------------------
-- ACCOUNT-LEVEL BUDGETS (Snowflake Budgets feature)
-- Prevents runaway spend on any single account. Budgets are instances of the
-- SNOWFLAKE.CORE.BUDGET class, monitor CREDIT usage against a monthly limit,
-- and are created PER ACCOUNT (run these in each child account — budgets are
-- not managed from the ORGADMIN account).
-- See https://docs.snowflake.com/en/user-guide/budgets
-- ---------------------------------------------------------------------------

-- Activate the built-in account-level budget and set its monthly credit limit:
-- CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!ACTIVATE();
-- CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(500);   -- credits/month

-- Custom budget scoped to specific objects (e.g. one warehouse or database):
-- CREATE SNOWFLAKE.CORE.BUDGET IF NOT EXISTS
--     MONITORING_DB.COST_MANAGEMENT.DEV_WORKLOAD_BUDGET();
-- CALL MONITORING_DB.COST_MANAGEMENT.DEV_WORKLOAD_BUDGET!SET_SPENDING_LIMIT(200);
-- Configure notification emails / recipients in Snowsight (Admin » Cost
-- Management » Budgets) or via the budget's notification methods.

-- ---------------------------------------------------------------------------
-- CROSS-ACCOUNT GOVERNANCE VIEWS
-- Run on the ORGADMIN account to get a unified view of all account activity.
-- ---------------------------------------------------------------------------

-- Note: These views query SNOWFLAKE.ORGANIZATION_USAGE (not ACCOUNT_USAGE).
-- This schema is only visible on the ORGADMIN account.

-- Credit usage by account (last 30 days)
CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_ORG_CREDIT_USAGE AS
SELECT
    account_name,
    region,
    service_type,
    usage_date,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used,
    credits_billed
FROM SNOWFLAKE.ORGANIZATION_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY account_name, usage_date;

-- Spend in contract currency by account (useful for finance reporting;
-- USAGE_IN_CURRENCY_DAILY reports currency amounts, not credit columns)
CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_ORG_SPEND_CURRENCY AS
SELECT
    account_name,
    region,
    usage_date,
    usage_type,
    currency,
    usage,
    usage_in_currency
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY account_name, usage_date;

-- Storage by account
CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_ORG_STORAGE AS
SELECT
    account_name,
    region,
    usage_date,
    average_bytes / POWER(1024, 4)  AS avg_storage_tb,
    credits                         AS storage_credits
FROM SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_DAILY_HISTORY
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY account_name, usage_date;

-- ---------------------------------------------------------------------------
-- ACCOUNT NAMING CONVENTION
-- ---------------------------------------------------------------------------
-- Format: <ORG>-<ENVIRONMENT>[-<REGION_SUFFIX_IF_MULTI_REGION>]
-- Examples:
--   ACME-DEV
--   ACME-STAGING
--   ACME-PROD
--   ACME-PROD-EU    (EU residency account, if required for GDPR)
--
-- The account identifier used in connection strings follows:
--   <org_name>-<account_name>  →  acme-prod.snowflakecomputing.com
