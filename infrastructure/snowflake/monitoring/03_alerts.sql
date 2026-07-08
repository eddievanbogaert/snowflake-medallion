-- =============================================================================
-- 03_alerts.sql
-- Snowflake Alerts trigger on conditions and send notifications via
-- email or webhook integrations.
--
-- Alert types configured here:
--   1. Failed logins (brute-force detection)
--   2. Data freshness (tables not loaded on schedule)
--   3. Long-running queries (runaway jobs)
--   4. dbt test failures (data quality regression)
--   5. Unexpected schema changes (DDL on production objects)
--
-- DESIGN NOTES
-- ------------
-- • SERVERLESS: alerts omit the WAREHOUSE parameter and run on serverless
--   compute. A 5–15 minute schedule against a warehouse with 60s auto-suspend
--   would otherwise keep that warehouse billing nearly continuously.
-- • LATENCY: SNOWFLAKE.ACCOUNT_USAGE views lag 45 minutes to 3 hours, so
--   conditions that need timely detection use INFORMATION_SCHEMA table
--   functions (seconds of latency, 7-day history) or query local tables
--   directly.
-- • NO GAPS: conditions filter on SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()
--   so events that arrive while an alert is suspended or a check fails are
--   still caught by the next successful evaluation.
--
-- Notification integration must be created first (email or Slack webhook).
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- STEP 1: NOTIFICATION INTEGRATION
-- ---------------------------------------------------------------------------

-- Email notification integration
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS EMAIL_NOTIFICATION
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = (
        'data-platform-alerts@mycompany.com',
        'security-alerts@mycompany.com'
    );

-- (Optional) Slack via a webhook notification integration. The payload uses
-- the SNOWFLAKE_WEBHOOK_MESSAGE placeholder, which SYSTEM$SEND_SNAPSHOT /
-- SYSTEM$TRIGGER_ACTION substitute at send time.
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS SLACK_NOTIFICATION
--     TYPE = WEBHOOK
--     ENABLED = TRUE
--     WEBHOOK_URL = 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
--     WEBHOOK_BODY_TEMPLATE = '{"text": "SNOWFLAKE_WEBHOOK_MESSAGE"}'
--     WEBHOOK_HEADERS = ('Content-Type'='application/json');

-- ---------------------------------------------------------------------------
-- STEP 2: ALERT — FAILED LOGIN SPIKE
-- Triggers if >5 failed logins occur since the last successful check.
-- Potential brute-force or credential stuffing attack indicator.
-- Uses INFORMATION_SCHEMA.LOGIN_HISTORY (near-real-time) — the ACCOUNT_USAGE
-- equivalent lags by up to 3 hours and would never match a 30-minute window.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_FAILED_LOGIN_SPIKE
    SCHEDULE = '5 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.LOGIN_HISTORY(
            TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            RESULT_LIMIT     => 10000
        ))
        WHERE is_success = 'NO'
          AND event_timestamp >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('minute', -30, CURRENT_TIMESTAMP())
              )
        HAVING COUNT(*) > 5
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com,security-alerts@mycompany.com',
            'ALERT: Snowflake Failed Login Spike Detected',
            'More than 5 failed Snowflake login attempts detected since the last check. '
            || 'Please review MONITORING_DB.AUDIT.VW_RECENT_FAILED_LOGINS immediately.'
        );

-- ---------------------------------------------------------------------------
-- STEP 3: ALERT — DATA FRESHNESS
-- Triggers if the raw customer landing table hasn't received a Fivetran sync
-- in >25 hours (expected load is at least daily).
-- Queries the landing table directly: zero latency, and loader-agnostic
-- (COPY_HISTORY only records COPY INTO / Snowpipe loads — Fivetran loads may
-- not appear there). Complements `dbt source freshness`, which enforces the
-- same SLA at transform time.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_CUSTOMERS_LOAD_LATE
    SCHEDULE = '1 HOUR'
    IF (EXISTS (
        SELECT 1
        FROM (
            SELECT MAX(_fivetran_synced) AS latest_sync
            FROM RAW_DB.SQLSERVER_RAW.CUSTOMERS
        )
        WHERE latest_sync < DATEADD('hour', -25, CURRENT_TIMESTAMP())
           OR latest_sync IS NULL
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: Customer Table Load Overdue',
            'The raw customer landing table (RAW_DB.SQLSERVER_RAW.CUSTOMERS) '
            || 'has not received new data in over 25 hours. '
            || 'Check the Fivetran/ADF pipeline status.'
        );

-- ---------------------------------------------------------------------------
-- STEP 4: ALERT — LONG RUNNING QUERIES
-- Triggers if any query exceeds 60 minutes execution time.
-- Uses INFORMATION_SCHEMA.QUERY_HISTORY — ACCOUNT_USAGE.QUERY_HISTORY only
-- contains COMPLETED queries, so a RUNNING filter there never matches.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_LONG_RUNNING_QUERY
    SCHEDULE = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
            RESULT_LIMIT => 10000
        ))
        WHERE execution_status = 'RUNNING'
          AND DATEDIFF('minute', start_time, CURRENT_TIMESTAMP()) > 60
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: Long-Running Snowflake Query Detected (>60 min)',
            'One or more Snowflake queries have been running for over 60 minutes. '
            || 'Review MONITORING_DB.AUDIT.VW_LONG_RUNNING_QUERIES and consider terminating '
            || 'runaway jobs with: SELECT SYSTEM$CANCEL_QUERY(''<query_id>'');'
        );

-- ---------------------------------------------------------------------------
-- STEP 5: ALERT — dbt TEST FAILURES
-- dbt's on-run-end hook (dbt/macros/data_quality_macros.sql:log_test_results)
-- writes every test result here after each prod invocation; the alert fires
-- on any 'fail' rows recorded since its last successful check.
-- ---------------------------------------------------------------------------

-- Table where dbt writes test result summaries (populated via on-run-end hook)
CREATE TABLE IF NOT EXISTS MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS (
    recorded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    run_id              VARCHAR(100),
    node_id             VARCHAR(500),
    test_name           VARCHAR(500),
    model_name          VARCHAR(500),
    status              VARCHAR(50),       -- pass, fail, warn, error
    failures            NUMBER,
    message             VARCHAR(2000)
);

GRANT INSERT ON TABLE MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
    TO ROLE TRANSFORMER_ROLE;
GRANT SELECT ON TABLE MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
    TO ROLE DATA_ENGINEER_ROLE;

CREATE ALERT IF NOT EXISTS ALERT_DBT_TEST_FAILURES
    SCHEDULE = '30 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
        WHERE status IN ('fail', 'error')
          AND recorded_at >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('hour', -1, CURRENT_TIMESTAMP())
              )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: dbt Data Quality Test Failures',
            'One or more dbt tests have failed since the last check. '
            || 'Query MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS for details.'
        );

-- ---------------------------------------------------------------------------
-- STEP 6: ALERT — UNEXPECTED DDL ON PRODUCTION
-- Triggers if CREATE, ALTER, or DROP is executed against ANALYTICS_DB
-- by someone other than the transformer service account.
-- Uses INFORMATION_SCHEMA.QUERY_HISTORY for near-real-time detection.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_UNEXPECTED_DDL
    SCHEDULE = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.QUERY_HISTORY(
            END_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
            RESULT_LIMIT         => 10000
        ))
        WHERE query_type IN ('CREATE', 'ALTER', 'DROP', 'RENAME', 'TRUNCATE_TABLE')
          AND database_name = 'ANALYTICS_DB'
          AND user_name  != 'SVC_DBT_TRANSFORMER'
          AND role_name NOT IN ('ACCOUNTADMIN', 'SYSADMIN')
          AND start_time >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('minute', -15, CURRENT_TIMESTAMP())
              )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com,security-alerts@mycompany.com',
            'ALERT: Unexpected DDL Detected on ANALYTICS_DB',
            'A CREATE/ALTER/DROP statement was executed on ANALYTICS_DB by a user '
            || 'other than the dbt service account. '
            || 'Review MONITORING_DB.AUDIT.VW_QUERY_HISTORY immediately.'
        );

-- ---------------------------------------------------------------------------
-- ENABLE ALL ALERTS
-- Alerts are created in SUSPENDED state by default; resume to activate.
-- ---------------------------------------------------------------------------

ALTER ALERT ALERT_FAILED_LOGIN_SPIKE   RESUME;
ALTER ALERT ALERT_CUSTOMERS_LOAD_LATE  RESUME;
ALTER ALERT ALERT_LONG_RUNNING_QUERY   RESUME;
ALTER ALERT ALERT_DBT_TEST_FAILURES    RESUME;
ALTER ALERT ALERT_UNEXPECTED_DDL       RESUME;
