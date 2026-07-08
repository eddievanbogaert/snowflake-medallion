-- =============================================================================
-- cortex/03_anomaly_monitoring.sql
-- ML-based anomaly detection on daily credit consumption — replaces static
-- "alert at N credits" thresholds with a learned baseline that understands
-- weekday/weekend seasonality and platform growth.
--
-- Pattern: SNOWFLAKE.ML.ANOMALY_DETECTION (unsupervised)
--   • weekly task retrains the model on the trailing 90 days
--   • daily task scores yesterday and stores flagged anomalies
--   • serverless alert emails when a new anomaly lands
--
-- The same pattern extends naturally to dbt test-failure rates
-- (MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS) and row-count drift.
--
-- COST: model training/scoring runs on the task's warehouse; keep the input
-- small (daily grain = 90 rows) and this is pennies.
--
-- Run as: ACCOUNTADMIN
-- Prerequisites: 30+ days of WAREHOUSE_METERING_HISTORY (else training fails);
--                monitoring/01_resource_monitors.sql (source view).
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MONITORING_DB;
USE SCHEMA COST_MANAGEMENT;

-- ---------------------------------------------------------------------------
-- 1. TRAINING INPUT: one row per day, account-wide credits
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDITS_TOTAL AS
SELECT
    usage_date::TIMESTAMP_NTZ AS usage_ts,
    SUM(credits_used)         AS total_credits
FROM MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDIT_USAGE
GROUP BY usage_date
ORDER BY usage_date;

-- ---------------------------------------------------------------------------
-- 2. MODEL (retrained weekly by the task below)
-- Initial creation — requires history; run once ~30 days after go-live:
-- ---------------------------------------------------------------------------

-- CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION
--     MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALY_MODEL(
--         INPUT_DATA        => TABLE(SELECT usage_ts, total_credits
--                                    FROM MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDITS_TOTAL
--                                    WHERE usage_ts >= DATEADD('day', -90, CURRENT_DATE())),
--         TIMESTAMP_COLNAME => 'USAGE_TS',
--         TARGET_COLNAME    => 'TOTAL_CREDITS',
--         LABEL_COLNAME     => ''            -- unsupervised
--     );

CREATE TASK IF NOT EXISTS MONITORING_DB.COST_MANAGEMENT.TASK_RETRAIN_CREDIT_ANOMALY_MODEL
    WAREHOUSE = ADMIN_WH
    SCHEDULE  = 'USING CRON 0 5 * * 1 UTC'   -- Mondays 05:00 UTC
    COMMENT   = 'Weekly retrain of the credit-spend anomaly model on trailing 90 days.'
AS
    CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION
        MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALY_MODEL(
            INPUT_DATA        => TABLE(SELECT usage_ts, total_credits
                                       FROM MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDITS_TOTAL
                                       WHERE usage_ts >= DATEADD('day', -90, CURRENT_DATE())),
            TIMESTAMP_COLNAME => 'USAGE_TS',
            TARGET_COLNAME    => 'TOTAL_CREDITS',
            LABEL_COLNAME     => ''
        );

-- ---------------------------------------------------------------------------
-- 3. DAILY SCORING into a findings table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALIES (
    detected_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    usage_ts      TIMESTAMP_NTZ,
    total_credits NUMBER(38, 9),
    forecast      NUMBER(38, 9),
    lower_bound   NUMBER(38, 9),
    upper_bound   NUMBER(38, 9),
    is_anomaly    BOOLEAN,
    percentile    FLOAT,
    distance      FLOAT
);

CREATE TASK IF NOT EXISTS MONITORING_DB.COST_MANAGEMENT.TASK_DETECT_CREDIT_ANOMALIES
    WAREHOUSE = ADMIN_WH
    SCHEDULE  = 'USING CRON 30 6 * * * UTC'  -- daily, after ACCOUNT_USAGE catches up
    COMMENT   = 'Scores the last 3 days of credit spend against the anomaly model.'
AS
BEGIN
    CALL MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALY_MODEL!DETECT_ANOMALIES(
        INPUT_DATA        => TABLE(SELECT usage_ts, total_credits
                                   FROM MONITORING_DB.COST_MANAGEMENT.VW_DAILY_CREDITS_TOTAL
                                   WHERE usage_ts >= DATEADD('day', -3, CURRENT_DATE())),
        TIMESTAMP_COLNAME => 'USAGE_TS',
        TARGET_COLNAME    => 'TOTAL_CREDITS'
    );
    INSERT INTO MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALIES
        (usage_ts, total_credits, forecast, lower_bound, upper_bound, is_anomaly, percentile, distance)
    SELECT ts, y, forecast, lower_bound, upper_bound, is_anomaly, percentile, distance
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    WHERE is_anomaly;
END;

-- Resume the tasks once the model exists (and EXECUTE TASK is granted):
-- ALTER TASK MONITORING_DB.COST_MANAGEMENT.TASK_RETRAIN_CREDIT_ANOMALY_MODEL RESUME;
-- ALTER TASK MONITORING_DB.COST_MANAGEMENT.TASK_DETECT_CREDIT_ANOMALIES RESUME;

-- ---------------------------------------------------------------------------
-- 4. ALERT on new anomalies
-- ---------------------------------------------------------------------------

CREATE ALERT IF NOT EXISTS ALERT_CREDIT_SPEND_ANOMALY
    SCHEDULE = '60 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALIES
        WHERE detected_at >= COALESCE(
                SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                DATEADD('hour', -24, CURRENT_TIMESTAMP())
              )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: Anomalous Snowflake credit consumption detected',
            'The ML anomaly model flagged unusual daily credit consumption. '
            || 'Review MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALIES and '
            || 'VW_DAILY_CREDIT_USAGE to identify the warehouse and workload.'
        );

ALTER ALERT ALERT_CREDIT_SPEND_ANOMALY RESUME;

GRANT SELECT ON TABLE MONITORING_DB.COST_MANAGEMENT.CREDIT_SPEND_ANOMALIES
    TO ROLE DATA_ENGINEER_ROLE;
