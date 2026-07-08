-- =============================================================================
-- 05_network_policies.sql
-- Restricts Snowflake access to approved IP ranges using NETWORK RULES
-- (schema-level, composable) attached to NETWORK POLICIES — the current
-- Snowflake pattern, replacing legacy inline ALLOWED_IP_LIST policies.
--
-- CIS Snowflake Foundations Benchmark controls addressed:
--   CIS 2.1 — network policy at the account level
--   CIS 2.2 — individual restrictive policies for service accounts
--
-- Strategy:
--   1. CORPORATE_NETWORK_POLICY — human users accessing via SSO.
--      Allows corporate office IPs and VPN egress IPs.
--   2. SERVICE_ACCOUNT_NETWORK_POLICY — service accounts.
--      Allows only the specific IPs of your integration tools
--      (Fivetran, ADF self-hosted IR, Power BI gateway, dbt Cloud).
--
-- IMPORTANT
-- ---------
--   • Replace ALL placeholder CIDRs with real values before applying. An
--     overly restrictive policy can lock out every user including you —
--     test with a single non-admin user first
--     (ALTER USER <test_user> SET NETWORK_POLICY = '<policy>').
--   • Network policies evaluate the PUBLIC egress IP that Snowflake sees.
--     Private RFC1918 ranges (10.0.0.0/8, 192.168.0.0/16) belong in a rule
--     ONLY when traffic arrives via AWS PrivateLink / Azure Private Link,
--     where the source is the private endpoint IP (see optional rule below).
--   • Do NOT allowlist shared cloud provider ranges to admit hosted CI
--     runners (e.g. an Azure /16 for GitHub-hosted runners) — that admits
--     every tenant in that region. Use self-hosted runners with a stable
--     egress IP, or deploy from inside Snowflake via dbt Projects on
--     Snowflake / Snowflake CLI instead.
--
-- Run as: ACCOUNTADMIN (grant), then SECURITYADMIN
-- =============================================================================

-- Network rules are schema-level objects; they live alongside the other
-- governance objects in MONITORING_DB.AUDIT.
USE ROLE ACCOUNTADMIN;
GRANT CREATE NETWORK RULE ON SCHEMA MONITORING_DB.AUDIT TO ROLE SECURITYADMIN;

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- NETWORK RULES
-- ---------------------------------------------------------------------------

CREATE OR REPLACE NETWORK RULE MONITORING_DB.AUDIT.NR_CORPORATE_EGRESS
    TYPE = IPV4
    MODE = INGRESS
    VALUE_LIST = (
        '203.0.113.0/24',       -- HQ public IP range          (placeholder — replace)
        '198.51.100.0/24',      -- Branch office range         (placeholder — replace)
        '192.0.2.10',           -- VPN egress 1 (FortiGate / Zscaler / etc. — replace)
        '192.0.2.11'            -- VPN egress 2                (placeholder — replace)
    )
    COMMENT = 'Public egress IPs for human users: offices and VPN concentrators.';

CREATE OR REPLACE NETWORK RULE MONITORING_DB.AUDIT.NR_INTEGRATION_TOOLS
    TYPE = IPV4
    MODE = INGRESS
    VALUE_LIST = (
        -- Fivetran egress IPs — use the current list for YOUR region:
        -- https://fivetran.com/docs/getting-started/ips
        '35.234.176.144/28',    -- Fivetran EU-West (example)
        '52.0.2.4',             -- Fivetran US-East (example)

        -- Azure Data Factory self-hosted Integration Runtime — the PUBLIC
        -- egress IP of the IR host (or its NAT gateway), not its private IP
        '198.51.100.50',        -- ADF IR public egress (placeholder — replace)

        -- Power BI on-premises gateway server — public egress IP
        '198.51.100.60',        -- PBI gateway public egress (placeholder — replace)

        -- dbt Cloud (if used):
        -- https://docs.getdbt.com/docs/cloud/about-cloud/access-regions-ip-addresses
        '52.22.161.231',        -- dbt Cloud US (example)
        '52.45.144.63'          -- dbt Cloud US (example)
    )
    COMMENT = 'Exact public egress IPs of ingestion and BI integration tools.';

-- (Optional) Private connectivity — uncomment ONLY if using AWS PrivateLink /
-- Azure Private Link, and list the private endpoint IPs Snowflake sees:
-- CREATE OR REPLACE NETWORK RULE MONITORING_DB.AUDIT.NR_PRIVATE_ENDPOINTS
--     TYPE = IPV4
--     MODE = INGRESS
--     VALUE_LIST = ('10.20.30.40')    -- VPC/VNet interface endpoint private IP
--     COMMENT = 'Private endpoint IPs (PrivateLink / Private Link traffic only).';

-- ---------------------------------------------------------------------------
-- NETWORK POLICIES (compose the rules)
-- ---------------------------------------------------------------------------

CREATE NETWORK POLICY IF NOT EXISTS CORPORATE_NETWORK_POLICY
    ALLOWED_NETWORK_RULE_LIST = ('MONITORING_DB.AUDIT.NR_CORPORATE_EGRESS')
    COMMENT = 'Restricts human user access to corporate network and VPN egress IPs.';

CREATE NETWORK POLICY IF NOT EXISTS SERVICE_ACCOUNT_NETWORK_POLICY
    ALLOWED_NETWORK_RULE_LIST = ('MONITORING_DB.AUDIT.NR_INTEGRATION_TOOLS')
    COMMENT = 'Restricts service account access to approved integration tool IPs only.';

-- ---------------------------------------------------------------------------
-- ASSIGN POLICIES TO USERS
-- ---------------------------------------------------------------------------

-- Service accounts get the tighter policy
ALTER USER SVC_LOADER           SET NETWORK_POLICY = 'SERVICE_ACCOUNT_NETWORK_POLICY';
ALTER USER SVC_DBT_TRANSFORMER  SET NETWORK_POLICY = 'SERVICE_ACCOUNT_NETWORK_POLICY';
ALTER USER SVC_POWERBI          SET NETWORK_POLICY = 'SERVICE_ACCOUNT_NETWORK_POLICY';

-- To apply to all human users at account level (uncomment AFTER confirming
-- the corporate rule covers every legitimate access path — CIS 2.1):
-- ALTER ACCOUNT SET NETWORK_POLICY = CORPORATE_NETWORK_POLICY;

-- ---------------------------------------------------------------------------
-- MAINTAINING RULES
-- Editing a rule updates every policy that references it — no policy change
-- needed when an office IP or vendor range rotates:
-- ALTER NETWORK RULE MONITORING_DB.AUDIT.NR_CORPORATE_EGRESS
--     SET VALUE_LIST = ('203.0.113.0/24', '198.51.100.0/24', '192.0.2.12');
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SHOW NETWORK POLICIES;
-- DESC NETWORK POLICY CORPORATE_NETWORK_POLICY;
-- SHOW NETWORK RULES IN SCHEMA MONITORING_DB.AUDIT;
-- DESC NETWORK RULE MONITORING_DB.AUDIT.NR_CORPORATE_EGRESS;
