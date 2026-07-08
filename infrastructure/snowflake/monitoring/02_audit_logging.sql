-- =============================================================================
-- 02_audit_logging.sql
-- Centralises audit logging views over SNOWFLAKE.ACCOUNT_USAGE.
--
-- Snowflake retains account usage data for 365 days.
-- These views expose common audit queries as reusable objects accessible
-- to DATA_ENGINEER_ROLE without requiring ACCOUNTADMIN access to raw usage views.
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MONITORING_DB;
USE SCHEMA AUDIT;

-- ---------------------------------------------------------------------------
-- LOGIN AUDIT
-- Tracks all login attempts including failures — critical for security monitoring.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_LOGIN_HISTORY AS
SELECT
    event_timestamp,
    user_name,
    client_ip,
    reported_client_type,
    reported_client_version,
    first_authentication_factor,
    second_authentication_factor,
    is_success,
    error_code,
    error_message,
    -- Flag suspicious logins
    CASE
        WHEN is_success = 'NO' THEN 'FAILED_LOGIN'
        WHEN second_authentication_factor IS NULL
             AND first_authentication_factor = 'PASSWORD'
             THEN 'NO_MFA_WARNING'
        ELSE 'OK'
    END AS security_flag
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
ORDER BY event_timestamp DESC;

-- Failed logins in the last 24 hours
CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_RECENT_FAILED_LOGINS AS
SELECT
    event_timestamp,
    user_name,
    client_ip,
    error_code,
    error_message
FROM MONITORING_DB.AUDIT.VW_LOGIN_HISTORY
WHERE is_success = 'NO'
  AND event_timestamp >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY event_timestamp DESC;

-- ---------------------------------------------------------------------------
-- QUERY AUDIT
-- Top queries by execution time and credit consumption.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_QUERY_HISTORY AS
SELECT
    query_id,
    query_text,
    database_name,
    schema_name,
    query_type,
    user_name,
    role_name,
    warehouse_name,
    warehouse_size,
    start_time,
    end_time,
    total_elapsed_time / 1000                  AS elapsed_seconds,
    bytes_scanned / POWER(1024, 3)             AS gb_scanned,
    rows_produced,
    credits_used_cloud_services,
    execution_status,
    error_code,
    error_message
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
ORDER BY start_time DESC;

-- Long-running queries (> 5 minutes) in last 7 days
CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_LONG_RUNNING_QUERIES AS
SELECT
    query_id,
    LEFT(query_text, 200)                       AS query_preview,
    user_name,
    role_name,
    warehouse_name,
    start_time,
    total_elapsed_time / 60000                  AS elapsed_minutes,
    gb_scanned,
    execution_status
FROM MONITORING_DB.AUDIT.VW_QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND elapsed_seconds > 300
ORDER BY elapsed_seconds DESC;

-- Expensive queries by bytes scanned (potential full-table scans)
CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_EXPENSIVE_QUERIES AS
SELECT
    query_id,
    LEFT(query_text, 200)                       AS query_preview,
    user_name,
    role_name,
    warehouse_name,
    start_time,
    elapsed_seconds,
    gb_scanned,
    rows_produced
FROM MONITORING_DB.AUDIT.VW_QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND gb_scanned > 10
ORDER BY gb_scanned DESC;

-- ---------------------------------------------------------------------------
-- GRANTS / PRIVILEGE CHANGE AUDIT
-- Any GRANT, REVOKE, or privilege change should be logged and reviewed.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_GRANT_HISTORY AS
SELECT
    start_time,
    user_name,
    role_name,
    query_type,
    LEFT(query_text, 500)                       AS query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_type IN ('GRANT', 'REVOKE')
  AND start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

-- ---------------------------------------------------------------------------
-- DATA ACCESS AUDIT
-- Tracks who accessed which tables — important for GDPR / audit requests.
-- ---------------------------------------------------------------------------

-- ACCESS_HISTORY has no role/query-type columns; join QUERY_HISTORY on
-- query_id to enrich each access record with the executing role.
CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_TABLE_ACCESS_HISTORY AS
SELECT
    ah.query_start_time,
    ah.user_name,
    qh.role_name,
    qh.query_type,
    ah.base_objects_accessed,   -- ARRAY of {objectDomain, objectName, columnNames}
    ah.direct_objects_accessed
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
    ON qh.query_id = ah.query_id
WHERE ah.query_start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
ORDER BY ah.query_start_time DESC;

-- Who accessed PII tables (flattened)
CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_PII_TABLE_ACCESS AS
SELECT
    ah.query_start_time,
    ah.user_name,
    qh.role_name,
    f.value:objectName::VARCHAR                 AS table_accessed,
    f.value:columns                             AS columns_accessed
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
    ON qh.query_id = ah.query_id,
     LATERAL FLATTEN(input => ah.base_objects_accessed) f
WHERE ah.query_start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
  AND (
      -- Filter to PII-bearing tables (update list to match your schema)
      f.value:objectName::VARCHAR ILIKE '%CUSTOMERS%'
   OR f.value:objectName::VARCHAR ILIKE '%CONTACTS%'
   OR f.value:objectName::VARCHAR ILIKE '%PATIENT%'
  )
ORDER BY ah.query_start_time DESC;

-- ---------------------------------------------------------------------------
-- USER OBJECT AUDIT
-- Lists all users, roles, and effective permissions — useful for access reviews.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_USER_ROLE_GRANTS AS
SELECT
    grantee_name     AS user_name,
    role             AS role_granted,
    granted_by,
    created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE deleted_on IS NULL
ORDER BY grantee_name, role;

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_ROLE_PRIVILEGE_GRANTS AS
SELECT
    grantee_name     AS role_name,
    privilege,
    granted_on,
    name             AS object_name,
    grant_option,
    granted_by,
    created_on
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE deleted_on IS NULL
ORDER BY grantee_name, granted_on, name;

-- ---------------------------------------------------------------------------
-- DATA LOADING AUDIT
-- Tracks all COPY INTO loads for bronze layer provenance.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_COPY_HISTORY AS
SELECT
    table_catalog_name,
    table_schema_name,
    table_name,
    file_name,
    stage_location,
    last_load_time,
    row_count,
    row_parsed,
    first_error_message,
    first_error_line_number,
    status,
    pipe_name
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE last_load_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY last_load_time DESC;

-- ---------------------------------------------------------------------------
-- GRANT VIEW ACCESS
-- ---------------------------------------------------------------------------

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_LOGIN_HISTORY           TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_RECENT_FAILED_LOGINS    TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_QUERY_HISTORY           TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_LONG_RUNNING_QUERIES    TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_EXPENSIVE_QUERIES       TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_GRANT_HISTORY           TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_TABLE_ACCESS_HISTORY    TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_PII_TABLE_ACCESS        TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_USER_ROLE_GRANTS        TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_ROLE_PRIVILEGE_GRANTS   TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_COPY_HISTORY            TO ROLE DATA_ENGINEER_ROLE;
