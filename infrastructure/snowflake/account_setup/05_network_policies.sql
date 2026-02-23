-- =============================================================================
-- 05_network_policies.sql
-- Restricts Snowflake access to approved IP ranges.
--
-- Strategy:
--   1. CORPORATE_NETWORK_POLICY — applied to human users accessing via SSO.
--      Allows corporate office IPs and VPN egress IPs.
--   2. SERVICE_ACCOUNT_POLICY — applied to service accounts.
--      Allows only the specific IPs of your integration tools
--      (Fivetran, ADF self-hosted IR, Power BI gateway, CI runners).
--
-- IMPORTANT: Replace placeholder CIDR ranges with real values for your org.
-- Applying an overly restrictive policy before confirming IPs can lock out all users.
-- Test with a single non-admin user before applying account-wide.
--
-- Run as: SECURITYADMIN
-- =============================================================================

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- CORPORATE NETWORK POLICY
-- Applied to human users authenticating via Azure AD SAML.
-- ---------------------------------------------------------------------------
CREATE NETWORK POLICY IF NOT EXISTS CORPORATE_NETWORK_POLICY
    ALLOWED_IP_LIST = (
        -- Corporate head office (example ranges — replace with real values)
        '203.0.113.0/24',       -- HQ public IP range
        '198.51.100.0/24',      -- Branch office range
        -- VPN egress IPs (FortiGate / Zscaler / etc.)
        '192.0.2.10',           -- VPN egress 1
        '192.0.2.11',           -- VPN egress 2
        -- Snowsight (managed access) — Snowflake's own NAT ranges if needed
        -- Add Azure-hosted runner IPs if analysts run notebooks in Azure
        '10.0.0.0/8'            -- Internal RFC1918 (remove if using public VPN egress only)
    )
    BLOCKED_IP_LIST = ()
    COMMENT = 'Restricts human user access to corporate network and VPN egress IPs.';

-- ---------------------------------------------------------------------------
-- SERVICE ACCOUNT NETWORK POLICY
-- Much tighter — only the exact IPs of integration tools.
-- ---------------------------------------------------------------------------
CREATE NETWORK POLICY IF NOT EXISTS SERVICE_ACCOUNT_NETWORK_POLICY
    ALLOWED_IP_LIST = (
        -- Fivetran egress IPs (see https://fivetran.com/docs/getting-started/ips)
        -- Replace with current Fivetran IP list for your region
        '35.234.176.144/28',    -- Fivetran EU-West (example)
        '52.0.2.4',             -- Fivetran US-East (example)

        -- Azure Data Factory self-hosted Integration Runtime
        '10.1.0.50',            -- ADF IR server (private IP — routed via VPN)

        -- Power BI on-premises gateway server
        '10.1.0.60',            -- PBI gateway server (private IP)

        -- GitHub Actions hosted runners (if CI deploys to Snowflake)
        -- See: https://api.github.com/meta (actions key) — rotate frequently
        '4.148.0.0/16',         -- Azure East US (GitHub Actions)

        -- dbt Cloud (if using dbt Cloud instead of self-hosted CI)
        -- See: https://docs.getdbt.com/docs/cloud/about-cloud/access-regions-ip-addresses
        '52.22.161.231',        -- dbt Cloud US (example)
        '52.45.144.63'          -- dbt Cloud US (example)
    )
    BLOCKED_IP_LIST = ()
    COMMENT = 'Restricts service account access to approved integration tool IPs only.';

-- ---------------------------------------------------------------------------
-- ASSIGN POLICIES TO USERS
-- ---------------------------------------------------------------------------

-- Service accounts get the tighter policy
ALTER USER SVC_LOADER           SET NETWORK_POLICY = SERVICE_ACCOUNT_NETWORK_POLICY;
ALTER USER SVC_DBT_TRANSFORMER  SET NETWORK_POLICY = SERVICE_ACCOUNT_NETWORK_POLICY;
ALTER USER SVC_POWERBI          SET NETWORK_POLICY = SERVICE_ACCOUNT_NETWORK_POLICY;

-- To apply to all human users at account level (uncomment after testing):
-- ALTER ACCOUNT SET NETWORK_POLICY = CORPORATE_NETWORK_POLICY;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SHOW NETWORK POLICIES;
-- DESC NETWORK POLICY CORPORATE_NETWORK_POLICY;
-- DESC NETWORK POLICY SERVICE_ACCOUNT_NETWORK_POLICY;
