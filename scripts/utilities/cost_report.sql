-- =============================================================================
-- cost_report.sql
-- Ad-hoc cost and credit consumption queries for platform engineers and
-- finance showback/chargeback reporting.
-- Run as: DATA_ENGINEER_ROLE (or SYSADMIN for full ACCOUNT_USAGE access)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. CURRENT MONTH SUMMARY BY WAREHOUSE
-- ---------------------------------------------------------------------------
SELECT
    warehouse_name,
    SUM(credits_used)                                    AS credits_used_mtd,
    SUM(credits_used_compute)                            AS credits_compute_mtd,
    SUM(credits_used_cloud_services)                     AS credits_cloud_services_mtd,
    ROUND(SUM(credits_used) * 3.00, 2)                   AS estimated_cost_usd_mtd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATE_TRUNC('month', CURRENT_DATE())
GROUP BY warehouse_name
ORDER BY credits_used_mtd DESC;

-- ---------------------------------------------------------------------------
-- 2. DAILY CREDIT TREND (last 30 days)
-- ---------------------------------------------------------------------------
SELECT
    TO_DATE(start_time)                                  AS usage_date,
    SUM(credits_used)                                    AS daily_credits,
    ROUND(SUM(credits_used) * 3.00, 2)                   AS daily_cost_usd,
    -- Rolling 7-day average
    AVG(SUM(credits_used)) OVER (
        ORDER BY TO_DATE(start_time)
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    )                                                    AS rolling_7d_avg
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY TO_DATE(start_time)
ORDER BY usage_date;

-- ---------------------------------------------------------------------------
-- 3. TOP 20 MOST EXPENSIVE QUERIES THIS WEEK (by bytes scanned)
-- ---------------------------------------------------------------------------
SELECT
    query_id,
    LEFT(query_text, 150)                                AS query_preview,
    user_name,
    role_name,
    warehouse_name,
    start_time,
    total_elapsed_time / 1000                            AS elapsed_seconds,
    bytes_scanned / POWER(1024, 3)                       AS gb_scanned,
    rows_produced,
    execution_status
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND bytes_scanned > 0
ORDER BY bytes_scanned DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 4. CREDIT USAGE BY USER (identify heavy consumers)
-- ---------------------------------------------------------------------------
SELECT
    qh.user_name,
    qh.role_name,
    wm.warehouse_name,
    COUNT(qh.query_id)                                   AS query_count,
    SUM(qh.bytes_scanned) / POWER(1024, 3)               AS total_gb_scanned,
    AVG(qh.total_elapsed_time / 1000)                    AS avg_elapsed_seconds,
    -- Rough credit attribution: credits * (elapsed / warehouse_active_seconds)
    ROUND(
        SUM(wm.credits_used) *
        SUM(qh.total_elapsed_time) /
        NULLIF(SUM(SUM(qh.total_elapsed_time)) OVER (PARTITION BY wm.warehouse_name), 0),
        4
    )                                                    AS estimated_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wm
    ON  wm.warehouse_name = qh.warehouse_name
    AND wm.start_time     <= qh.start_time
    AND wm.end_time       >= qh.start_time
WHERE qh.start_time >= DATE_TRUNC('month', CURRENT_DATE())
GROUP BY qh.user_name, qh.role_name, wm.warehouse_name
ORDER BY estimated_credits DESC NULLS LAST;

-- ---------------------------------------------------------------------------
-- 5. STORAGE COST ESTIMATE
-- ---------------------------------------------------------------------------
SELECT
    table_catalog                                        AS database_name,
    table_schema                                         AS schema_name,
    COUNT(*)                                             AS table_count,
    SUM(bytes) / POWER(1024, 4)                          AS total_tb,
    SUM(bytes_failsafe) / POWER(1024, 4)                 AS failsafe_tb,
    SUM(bytes_time_travel) / POWER(1024, 4)              AS time_travel_tb,
    -- Storage pricing: approx $23/TB/month (check your contract)
    ROUND((SUM(bytes) + SUM(bytes_failsafe) + SUM(bytes_time_travel))
          / POWER(1024, 4) * 23, 2)                      AS estimated_storage_cost_usd_month
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE deleted IS NULL
GROUP BY table_catalog, table_schema
ORDER BY total_tb DESC;

-- ---------------------------------------------------------------------------
-- 6. SERVERLESS CREDIT USAGE (Snowpipe, Auto-clustering, Materialized Views)
-- ---------------------------------------------------------------------------
SELECT
    usage_date,
    usage_type,
    SUM(credits_used)                                    AS credits_used,
    ROUND(SUM(credits_used) * 3.00, 2)                   AS estimated_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE usage_date >= DATE_TRUNC('month', CURRENT_DATE())
GROUP BY usage_date, usage_type
ORDER BY usage_date DESC, credits_used DESC;

-- ---------------------------------------------------------------------------
-- 7. AUTOMATED CLUSTERING SAVINGS ESTIMATE
-- Helps justify enabling Automatic Clustering on large tables.
-- ---------------------------------------------------------------------------
SELECT
    table_name,
    schema_name,
    database_name,
    active_bytes / POWER(1024, 3)                        AS active_gb,
    clustering_depth,
    average_overlaps,
    average_depth_ratio,
    -- High depth ratio = poor clustering = expensive full-table scans
    CASE
        WHEN average_depth_ratio > 3 THEN 'CONSIDER_CLUSTERING'
        WHEN average_depth_ratio BETWEEN 1.5 AND 3 THEN 'MODERATE_CLUSTERING'
        ELSE 'WELL_CLUSTERED'
    END                                                  AS clustering_recommendation
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE active_bytes > 1 * POWER(1024, 3)                  -- Only tables > 1 GB
  AND deleted IS NULL
ORDER BY average_depth_ratio DESC
LIMIT 20;
