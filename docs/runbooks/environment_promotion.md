# Environment Promotion Runbook

This runbook describes how to promote changes — dbt model changes, Snowflake infrastructure changes, and seed data updates — from development through to production.

This repo does not ship CI workflow files. The promotion mechanics below use **dbt Projects on Snowflake** (native execution, scheduled with tasks) and the **Snowflake CLI** (`snow`). If your organisation standardises on GitHub Actions/GitLab CI, wrap the same commands in workflows — the gates and checklists here still apply.

---

## Promotion path

```
Local dev  →  Feature branch (DEV_DB)  →  PR review + CI target  →  Staging  →  Production
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
dbt run --select <your_model> --target dev    # writes to DEV_DB.DBT_DEV_<username>_<layer schema>
dbt test --select <your_model>
```

### Step 2: Open a pull request

1. Push the feature branch and open a PR against `main`.
2. Validate against the CI target (locally or from your CI system):
   - `sqlfluff lint models/` — style checks pass.
   - `dbt build --target ci` — modified models and tests build in an
     ephemeral `TEST_DB.DBT_CI_<run_id>_*` schema set.
   - Drop the ephemeral schemas afterwards (or let a scheduled cleanup task
     drop `DBT_CI_%` schemas older than a day).
3. A second reviewer approves the PR.

### Step 3: Merge to main and deploy the dbt project

Merging to `main` does not change production by itself. Deploy the updated
project, then let the nightly task run it:

```bash
# Redeploy the DBT PROJECT object from the repo (Snowflake CLI)
cd dbt
snow dbt deploy SNOWFLAKE_MEDALLION --database FOUNDATION_DB --schema PUBLIC
```

The nightly production task executes the gate pattern in one invocation:

```sql
-- Defined once (see README "Deployment & Scheduling"):
-- EXECUTE DBT PROJECT FOUNDATION_DB.PUBLIC.SNOWFLAKE_MEDALLION ARGS='build --target prod'
```

`dbt build` interleaves run+test per node, so a failing silver test stops the
downstream gold models from building — no half-applied state reaches the gold
layer. Test failures are also written to
`MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS` (on-run-end hook), which feeds
`ALERT_DBT_TEST_FAILURES`.

For an urgent out-of-cycle run:

```sql
EXECUTE DBT PROJECT FOUNDATION_DB.PUBLIC.SNOWFLAKE_MEDALLION ARGS='build --target prod';
```

### Forcing a full refresh

Some schema migrations require `--full-refresh` (e.g., adding a column to an incremental model):

```sql
EXECUTE DBT PROJECT FOUNDATION_DB.PUBLIC.SNOWFLAKE_MEDALLION
    ARGS='build --target prod --full-refresh --select tag:silver';
```

> **Warning:** A full refresh on a high-volume incremental model can take significantly longer and consume more warehouse credits than a standard incremental run.

---

## 2. Promoting infrastructure (SQL) changes

Infrastructure changes (databases, roles, security policies, etc.) follow a stricter process because they modify account-level configuration that is harder to roll back.

### Step 1: Author and test the script

- All scripts must be idempotent (`CREATE IF NOT EXISTS`, `ALTER ... SET` rather than `CREATE`).
- Replace hardcoded values with `<PLACEHOLDER>` tokens for org-specific configuration.
- Test in a dev Snowflake account first using `bootstrap.sh --env dev --dry-run`, then without `--dry-run`.

### Step 2: Review and merge

- Run a secret scanner (e.g. `gitleaks`) over the branch; never commit credentials.
- Check for unresolved `<PLACEHOLDER>` tokens in any script being promoted.
- On merge, deploy the changed scripts explicitly:

```bash
snow sql -f infrastructure/snowflake/<area>/<changed_script>.sql \
    --temporary-connection --account <ORG>-staging \
    --user "$SNOWFLAKE_USER" --private-key-file "$SNOWFLAKE_PRIVATE_KEY_PATH" \
    --role <role from the script header>
```

### Step 3: Manual review of sensitive scripts

For scripts that touch **security policies, masking, row access, roles, or network policies**, require explicit approval from the Security Engineering team before merging:

1. Add the `security-review-required` label to the PR.
2. Tag `@security-engineering` in the PR description.
3. Do not merge until the label `security-approved` is added by a security engineer.

### Step 4: Manual verification after deploy

After deploying, confirm the change took effect:

```bash
# Connect to the target account
snow sql --account <account> ...

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
3. After merge and project redeploy, the nightly `dbt build` loads seeds automatically.
4. To promote immediately:
   `EXECUTE DBT PROJECT ... ARGS='seed --target prod --select tag:reference';`

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

`profiles.yml.example` ships `dev`, `ci`, and `prod` targets. For a staging
account, add a `staging` output (copy of `prod` pointing at
`<ORG>-staging`) and deploy/execute the dbt project in the staging account
before redeploying in production. Gate the production deploy on the staging
run succeeding.

---

## 5. Promotion checklist

Before any production deployment, confirm:

- [ ] `dbt build --target ci` passed on the PR (no test failures, no lint errors)
- [ ] Second reviewer approved the PR
- [ ] Any new PII columns carry `meta.pii_category` **and** `meta.masking_policy`
      in schema.yml (the post-hook applies tags + masking from that metadata)
- [ ] Any new gold model carries `meta.row_access_policy` and a `DATA_DOMAIN` column
- [ ] Managed access schemas are still in place (no `ALTER SCHEMA ... DISABLE MANAGED ACCESS`)
- [ ] `dbt docs generate` has been run and output is up to date
- [ ] Snowflake resource monitors cover any new warehouses
- [ ] If a schema change on an incremental model: `--full-refresh` flag is planned and capacity reserved
