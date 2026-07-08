-- =============================================================================
-- 04_privileged_access_alerts.sql
-- Security-focused alerts for privileged operations and configuration changes.
--
-- CIS Snowflake Foundations Benchmark controls addressed:
--   CIS 5.3 — Alert on ACCOUNTADMIN role usage
--   CIS 6.1 — Alert on network policy modifications
--   CIS 6.2 — Alert on user and role creation/deletion
--
-- These alerts complement the data-quality and operational alerts in 03_alerts.sql.
-- All alerts use the EMAIL_NOTIFICATION integration created in that file.
--
-- Run as: ACCOUNTADMIN
--
-- GOVERNMENT / PUBLIC SECTOR NOTES
-- ---------------------------------
-- • FedRAMP High environments must route alert email notifications through an
--   FedRAMP-authorized email service (e.g., Microsoft GCC High, not standard
--   Gmail/consumer SaaS). Update ALLOWED_RECIPIENTS in the EMAIL_NOTIFICATION
--   integration to use .mil or .gov-hosted addresses.
-- • DoD IL5: consider supplementing Snowflake native alerts with SIEM integration
--   (Splunk Cloud for Government, Microsoft Sentinel GCC High) via the Snowflake
--   Kafka connector or log export to a FedRAMP-authorized SIEM.
-- • ACCOUNTADMIN usage is especially sensitive in cleared facilities — consider
--   tightening the alert threshold or sending to a 24/7 SOC mailbox.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Confirm notification integration exists (created in 03_alerts.sql)
-- SHOW NOTIFICATION INTEGRATIONS;

-- ---------------------------------------------------------------------------
-- DESIGN: LATENCY AND GAP HANDLING
-- ---------------------------------------------------------------------------
-- SNOWFLAKE.ACCOUNT_USAGE views (LOGIN_HISTORY, QUERY_HISTORY) lag 45 minutes
-- to 3 hours. An alert that queries ACCOUNT_USAGE with a lookback shorter than
-- that latency will NEVER see the events it is checking for. Every condition
-- below therefore uses the INFORMATION_SCHEMA table functions (seconds of
-- latency, 7-day history).
--
-- Each condition also filters on LAST_SUCCESSFUL_SCHEDULED_TIME() with a
-- two-hour scan window, so events that occur while an alert is suspended or
-- an evaluation fails are still caught by the next successful run.
--
-- All alerts are SERVERLESS (no WAREHOUSE parameter): a 5–15 minute schedule
-- against ADMIN_WH would keep that warehouse resumed nearly continuously.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ALERT 1: ACCOUNTADMIN USAGE  (CIS 5.3)
-- Fires if ACCOUNTADMIN has been used for anything other than
-- SHOW/DESCRIBE/SELECT since the last successful check.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_ACCOUNTADMIN_USAGE
    SCHEDULE = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
            END_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            RESULT_LIMIT         => 10000
        ))
        WHERE role_name   = 'ACCOUNTADMIN'
          AND query_type NOT IN ('SHOW', 'DESCRIBE', 'SELECT')
          AND start_time >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('minute', -15, CURRENT_TIMESTAMP())
              )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'security-alerts@mycompany.com',
            'SECURITY ALERT: ACCOUNTADMIN Role Used for Privileged Operation',
            'The ACCOUNTADMIN role has been used to execute a non-read-only statement '
            || 'since the last check. This may indicate planned maintenance or a '
            || 'security incident. Review MONITORING_DB.AUDIT.VW_PRIVILEGED_OPERATIONS '
            || 'filtering role_name = ''ACCOUNTADMIN''.'
        );

-- ---------------------------------------------------------------------------
-- ALERT 2: NETWORK POLICY CHANGES  (CIS 6.1)
-- Network policy modifications could open access from unapproved IP ranges.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_NETWORK_POLICY_CHANGE
    SCHEDULE = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
            END_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            RESULT_LIMIT         => 10000
        ))
        WHERE (
              query_text ILIKE '%CREATE%NETWORK%POLICY%'
           OR query_text ILIKE '%ALTER%NETWORK%POLICY%'
           OR query_text ILIKE '%DROP%NETWORK%POLICY%'
           OR query_text ILIKE '%SET%NETWORK_POLICY%'
        )
        AND execution_status = 'SUCCESS'
        AND start_time >= COALESCE(
              SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
              DATEADD('minute', -15, CURRENT_TIMESTAMP())
            )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'security-alerts@mycompany.com',
            'SECURITY ALERT: Snowflake Network Policy Modified',
            'A Snowflake network policy was created, altered, dropped, or assigned '
            || 'since the last check. If this was not a planned change, review '
            || 'MONITORING_DB.AUDIT.VW_PRIVILEGED_OPERATIONS and check all network policy '
            || 'assignments immediately (SHOW NETWORK POLICIES; SHOW PARAMETERS LIKE '
            || '''NETWORK_POLICY'' IN ACCOUNT).'
        );

-- ---------------------------------------------------------------------------
-- ALERT 3: USER / ROLE LIFECYCLE CHANGES  (CIS 6.2)
-- User creation/deletion, role assignment, and password resets can indicate
-- privilege escalation or unauthorised account creation.
-- Note: SCIM-driven changes arrive via the SCIM REST API and do not appear in
-- QUERY_HISTORY, so no USERADMIN exclusion is needed — anything matching here
-- was executed via SQL.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_ROLE_GRANT_CHANGE
    SCHEDULE = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
            END_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            RESULT_LIMIT         => 10000
        ))
        WHERE query_type IN ('CREATE_USER', 'DROP_USER', 'ALTER_USER',
                             'CREATE_ROLE', 'DROP_ROLE',
                             'GRANT', 'REVOKE')
          AND execution_status = 'SUCCESS'
          AND start_time >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('minute', -15, CURRENT_TIMESTAMP())
              )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'security-alerts@mycompany.com',
            'SECURITY ALERT: Snowflake User/Role/Grant Change Detected',
            'A user, role, or grant change was executed via SQL since the last '
            || 'check (SCIM-provisioned changes do not appear here). '
            || 'Review MONITORING_DB.AUDIT.VW_GRANT_HISTORY and confirm the change '
            || 'was authorised via your change management process.'
        );

-- ---------------------------------------------------------------------------
-- ALERT 4: MASKING POLICY REMOVAL
-- Dropping or altering a masking policy could expose PII data.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_MASKING_POLICY_CHANGE
    SCHEDULE = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
            END_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            RESULT_LIMIT         => 10000
        ))
        WHERE (
              query_text ILIKE '%DROP%MASKING%POLICY%'
           OR query_text ILIKE '%ALTER%MASKING%POLICY%'
           OR query_text ILIKE '%UNSET%MASKING%POLICY%'
        )
        -- The dbt post-hook re-applies masking policies on every rebuild;
        -- exclude the transformer service account to avoid alerting on it.
        AND user_name != 'SVC_DBT_TRANSFORMER'
        AND execution_status = 'SUCCESS'
        AND start_time >= COALESCE(
              SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
              DATEADD('minute', -15, CURRENT_TIMESTAMP())
            )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'security-alerts@mycompany.com,data-platform-alerts@mycompany.com',
            'SECURITY ALERT: Snowflake Masking Policy Modified or Removed',
            'A dynamic data masking policy was altered, dropped, or unset from a '
            || 'column since the last check. This could expose PII data to '
            || 'unauthorised roles. Review MONITORING_DB.AUDIT.VW_MASKING_POLICY_COVERAGE '
            || 'and SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES immediately.'
        );

-- ---------------------------------------------------------------------------
-- ALERT 5: BREAK-GLASS ACCOUNT LOGIN
-- Fires if the emergency break-glass ACCOUNTADMIN user authenticates.
-- This should be rare; every use should be accompanied by a change ticket.
--
-- Uses INFORMATION_SCHEMA.LOGIN_HISTORY_BY_USER for near-real-time detection.
-- ACCOUNT_USAGE.LOGIN_HISTORY has 45-min to 3-hour latency and is NOT suitable
-- for a 5-minute alert schedule — do not revert this to ACCOUNT_USAGE.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_BREAKGLASS_LOGIN
    SCHEDULE = '5 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.LOGIN_HISTORY_BY_USER(
            USER_NAME        => 'ADMIN_BREAKGLASS',   -- Replace with actual break-glass account name
            TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            TIME_RANGE_END   => CURRENT_TIMESTAMP()
        ))
        WHERE is_success = 'YES'
          AND event_timestamp >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('minute', -5, CURRENT_TIMESTAMP())
              )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'security-alerts@mycompany.com',
            'CRITICAL ALERT: Snowflake Break-Glass Account Login Detected',
            'The emergency break-glass Snowflake account (ADMIN_BREAKGLASS) has '
            || 'successfully authenticated. If this was planned maintenance, ensure '
            || 'it is tracked in your change management system. If unexpected, '
            || 'treat this as a potential security incident and escalate immediately.'
        );

-- ---------------------------------------------------------------------------
-- ENABLE ALL ALERTS
-- ---------------------------------------------------------------------------

ALTER ALERT ALERT_ACCOUNTADMIN_USAGE      RESUME;
ALTER ALERT ALERT_NETWORK_POLICY_CHANGE   RESUME;
ALTER ALERT ALERT_ROLE_GRANT_CHANGE       RESUME;
ALTER ALERT ALERT_MASKING_POLICY_CHANGE   RESUME;
ALTER ALERT ALERT_BREAKGLASS_LOGIN        RESUME;

-- ---------------------------------------------------------------------------
-- AUDIT VIEW: PRIVILEGED OPERATIONS LOG
-- Centralises visibility into high-risk operations without requiring
-- DATA_ENGINEER_ROLE to query SNOWFLAKE.ACCOUNT_USAGE directly.
-- (Long-horizon forensics — ACCOUNT_USAGE latency is fine here.)
-- ---------------------------------------------------------------------------

USE DATABASE MONITORING_DB;
USE SCHEMA AUDIT;

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_PRIVILEGED_OPERATIONS AS
SELECT
    start_time,
    user_name,
    role_name,
    query_type,
    LEFT(query_text, 500)  AS query_preview,
    execution_status,
    warehouse_name
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE role_name IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN', 'USERADMIN')
   OR query_type IN (
        'CREATE_USER', 'DROP_USER', 'ALTER_USER',
        'CREATE_ROLE', 'DROP_ROLE',
        'GRANT', 'REVOKE',
        'CREATE_NETWORK_POLICY', 'ALTER_NETWORK_POLICY', 'DROP_NETWORK_POLICY'
   )
ORDER BY start_time DESC;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_PRIVILEGED_OPERATIONS
    TO ROLE DATA_ENGINEER_ROLE;
