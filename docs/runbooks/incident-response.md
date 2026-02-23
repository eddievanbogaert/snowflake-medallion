# Incident Response Runbook

## Severity Levels

| Level | Description | Response Time | Examples |
|-------|-------------|--------------|---------|
| SEV-1 | Production data loss or corruption | 15 min | Accidental DROP TABLE, wrong data in gold layer |
| SEV-2 | Pipeline failure blocking business decisions | 1 hour | dbt run failures, Snowpipe stopped |
| SEV-3 | Data quality degradation | 4 hours | Elevated dbt test failures, stale sources |
| SEV-4 | Non-critical issue | Next business day | Cost spike, slow query |

---

## Playbook 1: Accidental Table Drop / Data Deletion

### Immediate Actions (< 5 minutes)

```sql
-- 1. Attempt UNDROP immediately (within time travel retention window)
USE ROLE SYSADMIN;
UNDROP TABLE <fully_qualified_table_name>;

-- 2. If table was in a dropped schema:
UNDROP SCHEMA <database>.<schema_name>;

-- 3. If database was dropped:
UNDROP DATABASE <database_name>;
```

### If UNDROP Fails (table was outside retention window)

```sql
-- Check if a time-travel clone is possible
-- The table must have been dropped AFTER the retention start
SELECT
    table_name,
    deleted,
    retention_time
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE table_name = '<TABLE_NAME>'
  AND deleted IS NOT NULL
ORDER BY deleted DESC;

-- Clone from a specific point-in-time backup
CREATE TABLE <database>.<schema>.<table_name>_RECOVERY
    CLONE <database>.<schema>.<table_name>
    BEFORE (STATEMENT => '<last_known_good_query_id>');

-- Swap the recovery table into production after validation
ALTER TABLE <database>.<schema>.<table_name>
    SWAP WITH <database>.<schema>.<table_name>_RECOVERY;
```

### If Beyond Fail-Safe (> data retention + 7 days)

1. Contact Snowflake Support — they may be able to recover from internal backups
2. Re-ingest from source system (Fivetran full historical sync or ADF re-run)
3. Re-run dbt models to rebuild silver/gold from re-ingested bronze

### Post-Incident

- [ ] Identify root cause (who ran the DROP? Was it a test script, a misconfigured task, a rogue dbt run?)
- [ ] Check `MONITORING_DB.AUDIT.VW_GRANT_HISTORY` and `VW_QUERY_HISTORY` for context
- [ ] Review network policies — was the DROP from an unexpected IP?
- [ ] Add a Snowflake Alert for unexpected DDL (`ALERT_UNEXPECTED_DDL` in `03_alerts.sql`)
- [ ] Consider enabling Snowflake object-level locking for the affected table
- [ ] File incident report

---

## Playbook 2: dbt Pipeline Failure

### Diagnose

```bash
# View last run results (locally)
cd dbt
cat target/run_results.json | python3 -m json.tool | grep -A5 '"status": "error"'

# Or query Snowflake test failures table
snowsql -q "
SELECT test_name, model_name, status, failures, message
FROM MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
WHERE recorded_at >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
  AND status IN ('error', 'fail')
ORDER BY recorded_at DESC;
"
```

### Common Failures and Fixes

| Error | Likely Cause | Fix |
|-------|-------------|-----|
| `Insufficient privileges` | Role change or grant revoked | Re-run `03_roles.sql` grants section |
| `Object does not exist` | Source table dropped or renamed | Check bronze source; check Fivetran connector status |
| `Unique key constraint` | Duplicate PKs in source data | Check bronze DQ flags; run deduplication manually |
| `Syntax error` | Bad SQL in model | Fix model SQL; re-run in CI first |
| `Warehouse suspended` | Resource monitor limit hit | Check `MONITORING_DB.COST_MANAGEMENT` views; raise monitor limit if justified |

### Rerun a Specific Model

```bash
# Re-run a failed silver model and its downstream gold models
dbt run --select slv_customers+ --profiles-dir ~/.dbt --target prod

# Re-run with full refresh if schema mismatch
dbt run --select slv_customers+ --full-refresh --profiles-dir ~/.dbt --target prod

# Run just the failed tests to confirm fix
dbt test --select slv_customers --profiles-dir ~/.dbt --target prod
```

### Manual Trigger of Production Pipeline

Navigate to GitHub Actions → **dbt Production Run** → **Run workflow**.
Select `full_refresh: false` unless you need to rebuild incrementals from scratch.

---

## Playbook 3: Data Quality Alert (dbt Test Failures in Production)

### Assess Impact

```sql
-- How many rows are affected?
SELECT * FROM MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
WHERE status = 'fail'
  AND recorded_at >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY failures DESC;

-- Look at the stored failures (dbt stores up to 500 rows per failing test)
-- Failures are stored in the schema configured by +schema in dbt_project.yml
SELECT * FROM TEST_DB.DATA_QUALITY.<test_name>__failures LIMIT 100;
```

### Triage Decision

| Scenario | Action |
|----------|--------|
| Test failure on bronze (source data issue) | Escalate to source system owner; do NOT promote bad data to silver |
| Test failure on silver (transform bug) | Fix the model; re-run; flag impacted gold tables as stale |
| Test failure on gold (business logic) | Notify data product owner; evaluate whether dashboard data is trustworthy |
| Test failure rate < 0.1% | Log, monitor; don't block production |
| Test failure rate > 1% | Block Power BI refresh; escalate to SEV-2 |

### Blocking Power BI Refresh (when data is untrustworthy)

Until the issue is resolved, suspend the Power BI refresh:
1. Power BI Service → Datasets → your dataset → Settings → Scheduled refresh → toggle off
2. Notify affected stakeholders via `#data-platform` Slack channel
3. Add a banner to affected reports (Power BI: Report → Insert → Text box)

---

## Playbook 4: Security Incident (Suspected Unauthorised Access)

### Immediate Actions

```sql
-- 1. Identify the suspicious session
SELECT *
FROM MONITORING_DB.AUDIT.VW_LOGIN_HISTORY
WHERE event_timestamp >= DATEADD('hour', -4, CURRENT_TIMESTAMP())
  AND (is_success = 'NO' OR second_authentication_factor IS NULL)
ORDER BY event_timestamp DESC;

-- 2. Check what was accessed
SELECT *
FROM MONITORING_DB.AUDIT.VW_TABLE_ACCESS_HISTORY
WHERE user_name = '<suspect_user>'
  AND query_start_time >= DATEADD('hour', -4, CURRENT_TIMESTAMP());

-- 3. Check for data exfiltration signals (large result sets)
SELECT *
FROM MONITORING_DB.AUDIT.VW_QUERY_HISTORY
WHERE user_name = '<suspect_user>'
  AND rows_produced > 100000
  AND start_time >= DATEADD('hour', -24, CURRENT_TIMESTAMP());
```

### Containment

```sql
-- Immediately disable the suspect user account
USE ROLE USERADMIN;
ALTER USER <suspect_user> SET DISABLED = TRUE;

-- Revoke all active sessions (requires ACCOUNTADMIN)
USE ROLE ACCOUNTADMIN;
SELECT SYSTEM$ABORT_SESSION('<session_id>');  -- Abort specific session

-- Or abort all sessions for a user:
CALL SYSTEM$ABORT_TRANSACTION('<transaction_id>');
```

### Escalation

1. Notify `security@mycompany.com` immediately (SEV-1)
2. Do NOT delete audit logs — preserve evidence
3. Engage Snowflake Support if data exfiltration is confirmed
4. Follow your organisation's breach notification procedures (GDPR: 72-hour window)

---

## Playbook 5: Unexpected Cost Spike

### Diagnose

```sql
-- Top consumers today
SELECT warehouse_name, SUM(credits_used) AS credits_today
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= CURRENT_DATE()
GROUP BY warehouse_name
ORDER BY credits_today DESC;

-- Most expensive queries in last 24h
SELECT * FROM MONITORING_DB.AUDIT.VW_EXPENSIVE_QUERIES
ORDER BY gb_scanned DESC
LIMIT 20;

-- Check for rogue queries (analysts running full table scans)
SELECT user_name, COUNT(*) AS query_count, SUM(gb_scanned) AS total_gb_scanned
FROM MONITORING_DB.AUDIT.VW_EXPENSIVE_QUERIES
GROUP BY user_name
ORDER BY total_gb_scanned DESC;
```

### Immediate Cost Control

```sql
-- Immediately kill a runaway query
SELECT SYSTEM$CANCEL_QUERY('<query_id>');

-- Suspend a warehouse immediately
ALTER WAREHOUSE ANALYTICS_WH SUSPEND;

-- Lower a warehouse size temporarily
ALTER WAREHOUSE ANALYTICS_WH SET WAREHOUSE_SIZE = 'SMALL';
```

### Prevention

- Ensure all warehouses have resource monitors (`01_resource_monitors.sql`)
- Add query tags to all service account connections for attribution
- Consider enabling `MAX_CONCURRENCY_LEVEL` and `STATEMENT_TIMEOUT_IN_SECONDS` per warehouse
