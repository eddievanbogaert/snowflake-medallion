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
-- QUERY_ATTRIBUTION_HISTORY provides Snowflake's own per-query compute credit
-- attribution — no need to approximate by joining metering to query history.
-- (Note: excludes idle warehouse time, which is not attributable to a query.)
-- ---------------------------------------------------------------------------
SELECT
    qa.user_name,
    qa.warehouse_name,
    COUNT(qa.query_id)                                   AS query_count,
    ROUND(SUM(qa.credits_attributed_compute), 4)         AS credits_attributed,
    ROUND(SUM(qa.credits_attributed_compute) * 3.00, 2)  AS estimated_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY qa
WHERE qa.start_time >= DATE_TRUNC('month', CURRENT_DATE())
GROUP BY qa.user_name, qa.warehouse_name
ORDER BY credits_attributed DESC;

-- ---------------------------------------------------------------------------
-- 5. STORAGE COST ESTIMATE
-- ---------------------------------------------------------------------------
SELECT
    table_catalog                                        AS database_name,
    table_schema                                         AS schema_name,
    COUNT(*)                                             AS table_count,
    SUM(active_bytes) / POWER(1024, 4)                   AS active_tb,
    SUM(failsafe_bytes) / POWER(1024, 4)                 AS failsafe_tb,
    SUM(time_travel_bytes) / POWER(1024, 4)              AS time_travel_tb,
    SUM(retained_for_clone_bytes) / POWER(1024, 4)       AS clone_retained_tb,
    -- Storage pricing: approx $23/TB/month (check your contract)
    ROUND((SUM(active_bytes) + SUM(failsafe_bytes)
           + SUM(time_travel_bytes) + SUM(retained_for_clone_bytes))
          / POWER(1024, 4) * 23, 2)                      AS estimated_storage_cost_usd_month
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE NOT deleted
GROUP BY table_catalog, table_schema
ORDER BY active_tb DESC;

-- ---------------------------------------------------------------------------
-- 6. SERVERLESS AND NON-WAREHOUSE CREDIT USAGE
-- Covers Snowpipe, auto-clustering, materialized views, serverless tasks and
-- alerts, search optimization, replication, AI services, etc. — everything
-- billed outside warehouse metering. SERVICE_TYPE identifies the feature.
-- ---------------------------------------------------------------------------
SELECT
    usage_date,
    service_type,
    SUM(credits_used)                                    AS credits_used,
    ROUND(SUM(credits_used) * 3.00, 2)                   AS estimated_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= DATE_TRUNC('month', CURRENT_DATE())
  AND service_type != 'WAREHOUSE_METERING'   -- warehouse compute covered in query 1
GROUP BY usage_date, service_type
ORDER BY usage_date DESC, credits_used DESC;

-- ---------------------------------------------------------------------------
-- 7. CLUSTERING CANDIDATES
-- Large tables with no clustering key are candidates for a clustering key /
-- Automatic Clustering IF query patterns filter on a stable column. Confirm
-- with SYSTEM$CLUSTERING_INFORMATION before enabling — auto-clustering has an
-- ongoing serverless credit cost (see query 6, SERVICE_TYPE = AUTO_CLUSTERING).
-- ---------------------------------------------------------------------------
SELECT
    table_catalog                                        AS database_name,
    table_schema                                         AS schema_name,
    table_name,
    bytes / POWER(1024, 3)                               AS size_gb,
    row_count,
    clustering_key,
    auto_clustering_on
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE deleted IS NULL
  AND table_type = 'BASE TABLE'
  AND bytes > 1 * POWER(1024, 3)                         -- Only tables > 1 GB
  AND clustering_key IS NULL
ORDER BY bytes DESC
LIMIT 20;

-- Inspect clustering quality for a specific table and candidate key:
-- SELECT SYSTEM$CLUSTERING_INFORMATION('FOUNDATION_DB.EVENTS.SLV_EVENTS', '(event_date)');
