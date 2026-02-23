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
-- Requires: Snowflake Business Critical or Enterprise edition for full alert support.
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

-- (Optional) Slack webhook via AWS SNS or directly via API integration
-- CREATE NOTIFICATION INTEGRATION IF NOT EXISTS SLACK_NOTIFICATION
--     TYPE = WEBHOOK
--     ENABLED = TRUE
--     WEBHOOK_URL = 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
--     WEBHOOK_BODY_TEMPLATE = '{"text": "SNOWFLAKE ALERT: <SNOWFLAKE_ALERT_NAME> triggered at <SNOWFLAKE_ALERT_TIMESTAMP>. Condition: <SNOWFLAKE_CONDITION_QUERY_RESULT_ROWS> rows returned."}'
--     WEBHOOK_HEADERS = ('Content-Type'='application/json');

-- ---------------------------------------------------------------------------
-- STEP 2: ALERT — FAILED LOGIN SPIKE
-- Triggers if >5 failed logins occur in the last 30 minutes.
-- Potential brute-force or credential stuffing attack indicator.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_FAILED_LOGIN_SPIKE
    WAREHOUSE            = ADMIN_WH
    SCHEDULE             = '5 MINUTES'      -- Check every 5 minutes
    IF (EXISTS (
        SELECT 1
        FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
        WHERE is_success = 'NO'
          AND event_timestamp >= DATEADD('minute', -30, CURRENT_TIMESTAMP())
        HAVING COUNT(*) > 5
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com,security-alerts@mycompany.com',
            'ALERT: Snowflake Failed Login Spike Detected',
            'More than 5 failed Snowflake login attempts detected in the last 30 minutes. '
            || 'Please review MONITORING_DB.AUDIT.VW_RECENT_FAILED_LOGINS immediately.'
        );

-- ---------------------------------------------------------------------------
-- STEP 3: ALERT — DATA FRESHNESS
-- Triggers if the bronze customer table hasn't been loaded in >25 hours
-- (expected load is daily at ~midnight UTC).
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_CUSTOMERS_LOAD_LATE
    WAREHOUSE            = ADMIN_WH
    SCHEDULE             = '1 HOUR'
    IF (EXISTS (
        SELECT 1
        FROM (
            SELECT MAX(last_load_time) AS latest_load
            FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
            WHERE table_name = 'BRZ_SQLSERVER_CUSTOMERS'
              AND table_schema_name = 'SQLSERVER_RAW'
              AND status = 'Loaded'
        )
        WHERE latest_load < DATEADD('hour', -25, CURRENT_TIMESTAMP())
           OR latest_load IS NULL
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: Customer Table Load Overdue',
            'The bronze customer table (RAW_DB.SQLSERVER_RAW.BRZ_SQLSERVER_CUSTOMERS) '
            || 'has not been loaded in over 25 hours. '
            || 'Check the Fivetran/ADF pipeline status.'
        );

-- ---------------------------------------------------------------------------
-- STEP 4: ALERT — LONG RUNNING QUERIES
-- Triggers if any query exceeds 60 minutes execution time.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_LONG_RUNNING_QUERY
    WAREHOUSE            = ADMIN_WH
    SCHEDULE             = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
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
-- Triggered after dbt run by writing failures to a table; alert checks that table.
-- ---------------------------------------------------------------------------

-- Table where dbt writes test failure summaries (populated via on-run-end hook)
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
    WAREHOUSE            = ADMIN_WH
    SCHEDULE             = '30 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
        WHERE status = 'fail'
          AND recorded_at >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: dbt Data Quality Test Failures',
            'One or more dbt tests have failed in the last hour. '
            || 'Query MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS for details.'
        );

-- ---------------------------------------------------------------------------
-- STEP 6: ALERT — UNEXPECTED DDL ON PRODUCTION
-- Triggers if CREATE, ALTER, or DROP is executed against ANALYTICS_DB
-- by someone other than the transformer service account.
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_UNEXPECTED_DDL
    WAREHOUSE            = ADMIN_WH
    SCHEDULE             = '15 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE query_type IN ('CREATE', 'ALTER', 'DROP', 'RENAME', 'TRUNCATE_TABLE')
          AND database_name = 'ANALYTICS_DB'
          AND user_name NOT IN ('SVC_DBT_TRANSFORMER', 'ACCOUNTADMIN')
          AND role_name NOT IN ('ACCOUNTADMIN', 'SYSADMIN')
          AND start_time >= DATEADD('minute', -15, CURRENT_TIMESTAMP())
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

ALTER ALERT ALERT_FAILED_LOGIN_SPIKE    RESUME;
ALTER ALERT ALERT_CUSTOMERS_LOAD_LATE  RESUME;
ALTER ALERT ALERT_LONG_RUNNING_QUERY   RESUME;
ALTER ALERT ALERT_DBT_TEST_FAILURES    RESUME;
ALTER ALERT ALERT_UNEXPECTED_DDL       RESUME;
