# Environment Promotion Runbook

This runbook describes how to promote changes — dbt model changes, Snowflake infrastructure changes, and seed data updates — from development through to production.

---

## Promotion path

```
Local dev  →  Feature branch (DEV_DB)  →  PR review  →  Staging  →  Production
```

All changes must traverse this path. There is no direct deployment to production.

---

## 1. Promoting dbt model changes

### Step 1: Develop locally

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Run against your personal dev schema
cd dbt
dbt run --select <your_model> --target dev    # writes to DEV_DB.DBT_DEV_<username>
dbt test --select <your_model>
```

### Step 2: Open a pull request

1. Push the feature branch and open a PR against `main`.
2. The `dbt-ci.yml` workflow triggers automatically:
   - SQL compiles without errors.
   - SQLFluff style checks pass.
   - Only modified models (and their dependents) run in an ephemeral `TEST_DB.DBT_CI_<run_id>` schema.
   - All dbt tests pass.
   - CI schema is dropped on completion.
3. A second reviewer approves the PR.

### Step 3: Merge to main

Merging to `main` triggers:
- `dbt-production.yml` on the next nightly schedule (04:00 UTC), **or**
- Manually via workflow dispatch if the change is urgent.

The production run follows the gate pattern:
```
dbt seed  →  bronze+silver run  →  silver tests  →  gold run  →  gold tests  →  snapshots
```

If any gate fails, the run stops and a Slack notification is sent. No half-applied state reaches the gold layer.

### Forcing a full refresh

Some schema migrations require `--full-refresh` (e.g., adding a column to an incremental model). Trigger via GitHub Actions:

1. Go to **Actions → dbt Production Run → Run workflow**.
2. Set `full_refresh = true`.
3. Optionally set `select` to limit scope (e.g., `tag:silver` for silver models only).

> **Warning:** A full refresh on a high-volume incremental model can take significantly longer and consume more warehouse credits than a standard incremental run.

---

## 2. Promoting infrastructure (SQL) changes

Infrastructure changes (databases, roles, security policies, etc.) follow a stricter process because they modify account-level configuration that is harder to roll back.

### Step 1: Author and test the script

- All scripts must be idempotent (`CREATE IF NOT EXISTS`, `ALTER ... SET` rather than `CREATE`).
- Replace hardcoded values with `<PLACEHOLDER>` tokens for org-specific configuration.
- Test in a dev Snowflake account first using `bootstrap.sh --env dev --dry-run`.

### Step 2: Review and merge

The `snowflake-deploy.yml` workflow:
- Scans for hardcoded credentials (regex pattern match).
- Warns on remaining `<PLACEHOLDER>` tokens.
- On merge to `main`, deploys only the SQL files changed in that commit.

### Step 3: Manual review of sensitive scripts

For scripts that touch **security policies, masking, row access, roles, or network policies**, require explicit approval from the Security Engineering team before merging:

1. Add the `security-review-required` label to the PR.
2. Tag `@security-engineering` in the PR description.
3. Do not merge until the label `security-approved` is added by a security engineer.

### Step 4: Manual verification after deploy

After the workflow completes, confirm the change took effect:

```bash
# Connect to the target account
snowsql -a <account>

-- Example: verify a new role was created
SHOW ROLES LIKE 'MY_NEW_ROLE';

-- Example: verify managed access on a schema
SELECT schema_name, is_managed_access
FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA
WHERE catalog_name = 'ANALYTICS_DB';
```

### Rolling back infrastructure changes

Most infrastructure changes are additive (add a role, add a policy). Rolling back typically means:

```sql
-- Drop a role added by mistake
DROP ROLE IF EXISTS ERRONEOUSLY_CREATED_ROLE;

-- Restore a dropped policy (re-run the script that created it)
-- Script is idempotent; re-running it will re-create the object
```

For destructive changes (DROP TABLE, DROP SCHEMA), use time travel:

```sql
-- Recover a dropped table (within DATA_RETENTION_TIME_IN_DAYS)
UNDROP TABLE ANALYTICS_DB.FINANCE.GLD_REVENUE_SUMMARY;
```

See `docs/runbooks/incident-response.md` (Playbook 1) for the full data recovery procedure.

---

## 3. Promoting dbt seeds

Seed data (reference tables in `dbt/seeds/`) should be treated like code changes:

1. Update the CSV file in a feature branch.
2. PR includes a clear description of why the reference data changed (e.g., "Added Vietnam to ref_country_regions with GDPR = false").
3. After merge, the production nightly run executes `dbt seed --select tag:reference` automatically.
4. To promote immediately: run the `dbt Production Run` workflow manually with `select = tag:reference`.

Seeds are loaded with `--full-refresh` semantics (the entire CSV replaces the table). For large seeds (>100k rows), consider migrating to a proper source system and Bronze/Silver ingestion pattern instead.

---

## 4. Multi-account promotion

When running the Account-per-Environment topology (see `docs/architecture/multi_account_architecture.md`), the promotion sequence is:

```
DEV account (experimental) → STAGING account (validation) → PROD account
```

### Infrastructure changes

```bash
# Deploy to staging first
./scripts/setup/bootstrap.sh --env staging --account <ORG>-staging

# Validate staging behaviour — run dbt against staging, execute smoke tests

# Promote to prod (requires explicit confirmation prompt)
./scripts/setup/bootstrap.sh --env prod --account <ORG>-prod
```

### dbt changes

The `profiles.yml.example` includes `dev`, `ci`, `staging`, and `prod` targets. GitHub Actions uses the `ci` target for PR checks and `prod` for the nightly run. To add staging validation:

1. Add a `dbt-staging.yml` GitHub Actions workflow that runs on merge to `main`, targeting the staging Snowflake account.
2. Gate the production workflow on the staging workflow succeeding.

---

## 5. Promotion checklist

Before any production deployment, confirm:

- [ ] CI workflow passed on the PR (no test failures, no lint errors)
- [ ] Second reviewer approved the PR
- [ ] Any new PII columns are tagged (`DATA_SENSITIVITY`, `PII_CATEGORY`) and masked
- [ ] Managed access schemas are still in place (no `ALTER SCHEMA ... DISABLE MANAGED ACCESS`)
- [ ] New gold tables have `DATA_DOMAIN` column and row access policy applied
- [ ] `dbt docs generate` has been run and output is up to date
- [ ] Snowflake resource monitors cover any new warehouses
- [ ] If a schema change on an incremental model: `--full-refresh` flag is planned and capacity reserved
