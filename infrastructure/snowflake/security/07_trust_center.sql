-- =============================================================================
-- 07_trust_center.sql
-- Snowflake Trust Center: native, continuously-updated security posture
-- scanning — including a maintained CIS Snowflake Foundations Benchmark
-- scanner package.
--
-- HOW THIS RELATES TO 06_cis_compliance_checks.sql
-- -------------------------------------------------
-- The Trust Center's CIS Benchmarks scanner package evaluates the published
-- benchmark daily and tracks new benchmark revisions automatically. Use it as
-- the PRIMARY, always-current CIS posture signal. Keep
-- 06_cis_compliance_checks.sql for the checks that are specific to THIS
-- template (named alerts, managed-access schema list, template role names)
-- and as an auditable, self-contained evidence script.
--
-- SCANNER PACKAGES (managed in Snowsight: Monitoring » Trust Center »
-- Scanner Packages — package enablement is a UI operation):
--   • Security Essentials — enabled by default. Checks MFA enforcement via
--     authentication policies (see 08_authentication_policies.sql) and
--     account-level network policy coverage (05_network_policies.sql).
--   • CIS Benchmarks — ENABLE THIS. Evaluates the CIS Snowflake Foundations
--     Benchmark (39 checkpoints) daily; schedule is configurable.
--   • Threat Intelligence — recommended; flags risky users/integrations.
--
-- COST: scanner package executions bill as serverless TRUST_CENTER credits —
-- visible in cost_report.sql query 6 (SERVICE_TYPE = 'TRUST_CENTER').
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- ACCESS: who can administer and who can read findings
-- TRUST_CENTER_ADMIN — enable/disable scanner packages, set schedules
-- TRUST_CENTER_VIEWER — read the Findings dashboard and FINDINGS data
-- ---------------------------------------------------------------------------

GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_ADMIN  TO ROLE SECURITYADMIN;
GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_VIEWER TO ROLE DATA_ENGINEER_ROLE;

-- ---------------------------------------------------------------------------
-- ENABLEMENT CHECKLIST (Snowsight, as a TRUST_CENTER_ADMIN grantee)
-- ---------------------------------------------------------------------------
-- 1. Snowsight → Monitoring → Trust Center → Scanner Packages
-- 2. Enable "CIS Benchmarks"; keep the default daily schedule (or align it
--    with your compliance reporting cadence)
-- 3. Enable "Threat Intelligence" (recommended)
-- 4. Confirm "Security Essentials" shows as enabled (default)
-- 5. Review Findings weekly; export violations into your ticketing system

-- ---------------------------------------------------------------------------
-- QUERY FINDINGS PROGRAMMATICALLY
-- The Findings view lists each scanner violation with severity and the
-- offending entities. Wire the summary below into the quarterly compliance
-- review (docs/architecture/cis_benchmark_compliance.md).
-- ---------------------------------------------------------------------------

-- Current open findings by severity:
-- SELECT scanner_package_name,
--        scanner_name,
--        severity,
--        total_at_risk_count,
--        event_time
-- FROM SNOWFLAKE.TRUST_CENTER.FINDINGS
-- WHERE event_time = (SELECT MAX(event_time) FROM SNOWFLAKE.TRUST_CENTER.FINDINGS)
-- ORDER BY CASE severity
--            WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
--            WHEN 'MEDIUM'   THEN 3 ELSE 4 END;
