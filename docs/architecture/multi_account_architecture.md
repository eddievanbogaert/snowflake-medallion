# Multi-Account Architecture Guide

This guide explains when and how to structure a Snowflake deployment across multiple accounts, and how the scripts in `infrastructure/snowflake/multi_account/` support each pattern.

---

## Why Multiple Accounts?

A single Snowflake account is sufficient for many organizations, but multiple accounts become valuable when you need:

- **Environment isolation** — dev/staging/prod share a single billing agreement but cannot accidentally read each other's data.
- **Compliance / data residency** — GDPR requires EU personal data to stay in the EU. A separate EU account satisfies this without complex per-table policies.
- **Business unit isolation** — two BUs with conflicting access requirements (e.g., Finance cannot see Marketing's customer PII) are easier to manage in separate accounts than with elaborate RBAC in one.
- **Blast radius reduction** — a misconfiguration in the dev account cannot drop a production table.
- **Cost separation** — separate accounts produce separate invoices, making cross-charge easier.

---

## Topology Options

### Option A: Account-per-Environment (recommended for most)

```
Snowflake Organisation
├── <ORG>-DEV       (Enterprise edition)
├── <ORG>-STAGING   (Enterprise edition)
└── <ORG>-PROD      (Business Critical — required for Failover Groups)
    └── <ORG>-PROD-DR  (Business Critical — DR replica in secondary region)
```

**Best for:** Organizations of any size that want simple environment isolation and a clear promotion path. The DR account is optional but recommended for any production SLA.

**Data flow:**
- Fivetran / ADF land data into `<ORG>-PROD` only.
- dbt CI runs in `<ORG>-STAGING` (or `TEST_DB` within `<ORG>-PROD`).
- Analysts and Power BI connect to `<ORG>-PROD`.

### Option B: Account-per-Business-Unit

```
Snowflake Organisation
├── <ORG>-SHARED-SERVICES  (reference data, platform tooling)
├── <ORG>-FINANCE          (Finance BU — isolated PII)
├── <ORG>-MARKETING        (Marketing BU)
└── <ORG>-OPERATIONS       (Operations / Supply Chain)
```

**Best for:** Large enterprises where BUs operate independently, have separate data engineering teams, or have conflicting compliance requirements. Adds complexity — prefer Option A unless you have a clear need.

**Data flow:**
- Each BU account has its own ingestion pipelines.
- `SHARED-SERVICES` publishes reference data via Secure Data Sharing.
- Cross-BU analytics (e.g., Finance + Marketing join) requires a shared analytics account or materialised cross-account views.

### Option C: Hub-and-Spoke (advanced)

```
Snowflake Organisation
├── <ORG>-PROD         (hub: raw + silver)
├── <ORG>-ANALYTICS    (spoke: gold + BI)  ← consumes via Secure Share
├── <ORG>-DATASCIENCE  (spoke: ML workloads) ← consumes via Secure Share
└── <ORG>-GOVERNANCE   (spoke: audit + compliance) ← receives replicated MONITORING_DB
```

**Best for:** Organizations that want to decouple production data from BI/DS compute, or need a fully isolated governance account where audit logs cannot be altered by production admins.

---

## Enabling Snowflake Organizations

Every Snowflake account already belongs to an organization. To manage it:

1. Enable the `ORGADMIN` role on your primary account (Snowsight: Admin » Accounts;
   long-lived legacy accounts may need to ask their Snowflake account team).
2. Grant `ORGADMIN` to the platform administrators who provision accounts.
3. Once enabled, the `ORGADMIN` role appears in `SHOW ROLES`.

After enablement, follow `infrastructure/snowflake/multi_account/01_organizations_setup.sql` to provision child accounts and configure billing budgets.

---

## Account Bootstrapping for New Environments

Each new account should have the full `bootstrap.sh` run against it. The only differences between environments are:

| Setting | DEV | STAGING | PROD |
|---------|-----|---------|------|
| `TIME_TRAVEL_IN_DAYS` | 1 day | 7 days | 14–30 days |
| Snowflake edition | Enterprise | Enterprise | Business Critical |
| Network policy | Relaxed (allow dev IPs) | Same as prod | Strict (corp + VPN only) |
| Resource monitor limits | Low ($50–100/month) | Medium | Unlimited (alerted) |
| Replication | None | None | Enabled to DR account |
| SCIM | Optional | Optional | Required |

Bootstrap command:

```bash
# Bootstrap a new environment account
./scripts/setup/bootstrap.sh --env dev --account <ORG>-dev
./scripts/setup/bootstrap.sh --env staging --account <ORG>-staging
./scripts/setup/bootstrap.sh --env prod --account <ORG>-prod
```

See `docs/runbooks/environment_promotion.md` for the process of promoting dbt models and infrastructure changes across environments.

---

## Cross-Account Data Sharing

Snowflake [Secure Data Sharing](https://docs.snowflake.com/en/user-guide/data-sharing-intro) allows read-only, near-zero-latency access to data across accounts with no data copying.

**Key properties:**
- Data stays in the provider account's storage; consumers query it directly.
- Masking policies and row access policies on the provider are enforced — consumers cannot bypass them.
- Consumer account pays for compute (warehouse credits) to query the share.
- Shares work across accounts in the same organisation without additional setup.

Implementation: `infrastructure/snowflake/multi_account/02_cross_account_sharing.sql`

### What to share across environments

| Share | Provider | Consumer(s) | Contents |
|-------|----------|-------------|----------|
| `ANALYTICS_SHARE` | PROD | STAGING, BI account | Gold-layer tables (read-only) |
| `REFERENCE_DATA_SHARE` | PROD | DEV, STAGING | Reference/seed tables |
| `MONITORING_SHARE` | PROD | GOVERNANCE account | Cost views, DQ results |

### Secure View pattern

When a gold table contains data from multiple tenants or domains, create a `SECURE VIEW` that filters to the consumer's scope before adding it to the share:

```sql
CREATE OR REPLACE SECURE VIEW ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360_SHARED AS
SELECT * FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
WHERE data_domain = 'MARKETING';

GRANT SELECT ON VIEW ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360_SHARED
    TO SHARE ANALYTICS_SHARE;
```

The `SECURE` keyword hides the view definition from the consumer account, protecting filter logic.

---

## Failover / Disaster Recovery

Snowflake [Failover Groups](https://docs.snowflake.com/en/user-guide/account-replication-failover) (Business Critical edition) replicate databases *and* account-level objects (users, roles, warehouses, network policies) as a consistent unit.

**RPO/RTO targets for this template:**

| Metric | Target | Mechanism |
|--------|--------|-----------|
| Recovery Point Objective (RPO) | 10 minutes | `REPLICATION_SCHEDULE = '10 MINUTES'` in `PROD_FAILOVER_GROUP` |
| Recovery Time Objective (RTO) | ~5 minutes | `ALTER FAILOVER GROUP ... PRIMARY` promotes secondary instantly |

**Replication cost:** Snowflake charges for data transfer between regions and for the storage of the replicated copy. For most organizations, this is a small fraction of total compute costs.

Implementation: `infrastructure/snowflake/multi_account/03_account_replication.sql`

### Failover runbook (brief)

1. Confirm replication lag: `SELECT phase_name, start_time, end_time FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('PROD_FAILOVER_GROUP')) ORDER BY start_time DESC;`
2. On the DR account: `ALTER FAILOVER GROUP PROD_FAILOVER_GROUP PRIMARY`.
3. Update Fivetran destination, dbt profile, and Power BI data source to point to the new primary account identifier.
4. Validate dbt `source freshness` and run a smoke test query on each gold table.
5. Notify stakeholders; open a post-incident review.

---

## Multi-Account dbt Configuration

When running dbt across multiple environments, the `profiles.yml` should have one output per account:

```yaml
snowflake_medallion:
  target: prod
  outputs:
    dev:
      account: "acme-dev"
      database: DEV_DB
      schema: "DBT_DEV_{{ env_var('DBT_USER') }}"
      # ...
    staging:
      account: "acme-staging"
      database: FOUNDATION_DB
      schema: STAGING
      # ...
    prod:
      account: "acme-prod"
      database: FOUNDATION_DB
      schema: PROD
      # ...
```

CI always targets the `staging` or `ci` profile. Production nightly runs target `prod`. See `dbt/profiles.yml.example`.

---

## Cost Allocation in a Multi-Account Setup

With Snowflake Organizations enabled, use the `SNOWFLAKE.ORGANIZATION_USAGE` views on the ORGADMIN account to see spend broken down by account. This enables:

- Per-account budget alerts (prevent dev from overspending).
- Cross-charge / show-back reports for each BU.
- Side-by-side comparison of compute costs between environments.

The `VW_ORG_CREDIT_USAGE` and `VW_ORG_STORAGE` views in `01_organizations_setup.sql` provide this reporting.
