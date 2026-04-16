# Snowflake Medallion Architecture

An enterprise-grade Snowflake data platform reference implementation featuring a
medallion (Bronze → Silver → Gold) architecture with full security, observability,
and governance controls — aligned to the **CIS Snowflake Foundations Benchmark**.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          DATA SOURCES                                   │
│   SQL Server (Legacy)      AWS S3 (Files)      Snowflake Native         │
└──────────────┬─────────────────┬──────────────────────┬────────────────┘
               │                 │                      │
               ▼                 ▼                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     BRONZE LAYER  (RAW_DB)                              │
│          Raw, unmodified ingestion — schema-on-read, immutable          │
│   • Snowpipe for S3 auto-ingest        • External stages                │
│   • ADF / Fivetran for SQL Server      • Full audit metadata            │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │  dbt (validation + type casting)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    SILVER LAYER  (FOUNDATION_DB)                        │
│     Cleansed, validated, conformed — single source of truth             │
│   • Null checks / referential integrity   • SCD Type 2 snapshots        │
│   • Standardised column naming            • PII masking applied         │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │  dbt (business logic + aggregations)
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      GOLD LAYER  (ANALYTICS_DB)                         │
│          Curated, domain-oriented data products                         │
│   • Customer 360           • Revenue summary                            │
│   • Product performance    • Row-level security enforced                │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        CONSUMPTION LAYER                                │
│   Microsoft Power BI (SAML/OAuth + AD group RLS)                        │
│   Data Science / ML workloads      Ad-hoc SQL (analysts)                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
snowflake-medallion/
├── .github/
│   └── workflows/
│       ├── dbt-ci.yml                  # PR validation: compile, lint, run, test
│       ├── dbt-production.yml          # Nightly production run with Slack alerts
│       └── snowflake-deploy.yml        # Infrastructure change deployment
├── docs/
│   ├── architecture/
│   │   ├── security-model.md           # RBAC hierarchy, masking, RLS, audit
│   │   ├── cis_benchmark_compliance.md # CIS Snowflake Benchmark control mapping
│   │   └── multi_account_architecture.md # Multi-account topology guide
│   └── runbooks/
│       ├── onboarding.md               # New developer setup guide
│       ├── incident-response.md        # 5 incident playbooks (data loss, pipeline, etc.)
│       └── environment_promotion.md    # How to promote changes dev → staging → prod
├── infrastructure/
│   └── snowflake/
│       ├── account_setup/
│       │   ├── 01_databases.sql        # Databases and schemas
│       │   ├── 02_warehouses.sql       # Warehouse sizing and auto-suspend
│       │   ├── 03_roles.sql            # RBAC role hierarchy and grants
│       │   ├── 04_users.sql            # Service accounts and human user templates
│       │   ├── 05_network_policies.sql # IP allowlisting (CIS 2.1/2.2)
│       │   ├── 06_password_policies.sql # Strong password + session timeout (CIS 1.3/1.4)
│       │   └── 07_scim_integration.sql # Azure AD SCIM provisioning (CIS 1.6)
│       ├── security/
│       │   ├── 01_object_tags.sql      # DATA_SENSITIVITY, PII_CATEGORY, COMPLIANCE_SCOPE tags
│       │   ├── 02_data_classification.sql # Tag application to tables/columns
│       │   ├── 03_column_masking_policies.sql # PII dynamic masking (email, phone, name, DOB, ...)
│       │   ├── 04_row_access_policies.sql # Domain isolation, tenant, regional residency RLS
│       │   ├── 05_managed_access_schemas.sql # Prevent privilege escalation (CIS 3.5)
│       │   └── 06_cis_compliance_checks.sql  # Audit queries for every CIS control
│       ├── monitoring/
│       │   ├── 01_resource_monitors.sql # Credit consumption alerts per warehouse
│       │   ├── 02_audit_logging.sql     # Audit views over SNOWFLAKE.ACCOUNT_USAGE
│       │   ├── 03_alerts.sql            # Operational alerts (freshness, DQ, DDL)
│       │   └── 04_privileged_access_alerts.sql # Security alerts (CIS 5.3/6.1/6.2)
│       ├── integrations/               # S3 storage integration, Snowpipe, SQL Server
│       ├── backup/                     # Time travel config, cross-region replication
│       └── multi_account/
│           ├── 01_organizations_setup.sql   # Snowflake Organizations + account provisioning
│           ├── 02_cross_account_sharing.sql # Secure Data Sharing between accounts
│           └── 03_account_replication.sql   # Failover Groups for HA/DR
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml.example            # Connection template (copy to ~/.dbt/profiles.yml)
│   ├── packages.yml                    # dbt_utils, dbt_expectations, audit_helper, elementary
│   ├── models/
│   │   ├── bronze/
│   │   │   ├── sources.yml             # Source definitions with freshness checks
│   │   │   ├── sqlserver/              # brz_sqlserver_{customers,orders,order_items,products}
│   │   │   └── s3/                     # brz_s3_{events,transactions}
│   │   ├── silver/
│   │   │   ├── customers/              # slv_customers
│   │   │   ├── orders/                 # slv_orders, slv_order_items
│   │   │   ├── products/               # slv_products
│   │   │   └── events/                 # slv_events
│   │   └── gold/
│   │       ├── marketing/              # gld_customer_360
│   │       ├── finance/                # gld_revenue_summary
│   │       └── operations/             # gld_product_performance
│   ├── seeds/
│   │   ├── _seeds.yml                  # Seed column types, tests, and documentation
│   │   ├── ref_data_domains.csv        # Business domain definitions and PBI role mappings
│   │   └── ref_country_regions.csv     # ISO country → GDPR/CCPA/residency zone mapping
│   ├── macros/                         # audit_columns, generate_schema_name, safe_cast_*, etc.
│   ├── snapshots/                      # snp_customers (SCD Type 2)
│   └── tests/singular/                 # Business-rule tests across all layers
├── powerbi/
│   ├── saml_oauth_setup.md             # Azure AD SSO + OAuth integration guide
│   └── row_level_security/
│       ├── rls_snowflake_setup.sql     # Applies row access + masking policies to gold tables
│       └── rls_policies.md             # AD group → role → data access matrix
└── scripts/
    ├── setup/
    │   └── bootstrap.sh                # Ordered, role-aware execution of all infra scripts
    └── utilities/
        ├── clone_for_dev.sh            # Zero-copy dev/test clones from production schemas
        └── cost_report.sql             # Credit consumption and storage cost queries
```

---

## Quick Start

### Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Snowflake account | Enterprise edition or higher | Business Critical for Failover Groups |
| Python | 3.11+ | Use `pyenv` to manage versions |
| dbt-snowflake | 1.8.x | See `dbt/packages.yml` for exact constraint |
| SnowSQL | 1.2.x | For running infrastructure scripts |
| AWS CLI | 2.x | Required for S3 storage integration setup |
| Azure CLI | latest | Required for Azure AD / SAML SSO + SCIM configuration |

### 1. Clone and configure

```bash
git clone https://github.com/your-org/snowflake-medallion.git
cd snowflake-medallion
cp .env.example .env
# Edit .env with your Snowflake account identifier and credential paths
```

### 2. Bootstrap Snowflake infrastructure

Each script specifies its required role in the header comment. The bootstrap script
handles role switching automatically:

```bash
chmod +x scripts/setup/bootstrap.sh
./scripts/setup/bootstrap.sh --env dev --account <your-account>

# For production (requires explicit confirmation):
./scripts/setup/bootstrap.sh --env prod --account <your-prod-account>
```

Or run individual phases manually:

```bash
# Account setup (databases, warehouses, roles, users, network policies,
#                password policy, session policy, SCIM integration)
snowsql -f infrastructure/snowflake/account_setup/01_databases.sql
# ... through 07_scim_integration.sql

# Security controls (tags, masking, row access, managed access schemas)
snowsql -f infrastructure/snowflake/security/01_object_tags.sql
# ... through 05_managed_access_schemas.sql

# Monitoring and alerting (resource monitors, audit views, operational + security alerts)
snowsql -f infrastructure/snowflake/monitoring/01_resource_monitors.sql
# ... through 04_privileged_access_alerts.sql

# External integrations (S3, Snowpipe, SQL Server)
snowsql -f infrastructure/snowflake/integrations/01_storage_integration_s3.sql
snowsql -f infrastructure/snowflake/integrations/02_external_stages.sql
snowsql -f infrastructure/snowflake/integrations/03_sqlserver_integration.sql
```

After bootstrapping, verify your CIS compliance posture:

```bash
snowsql -f infrastructure/snowflake/security/06_cis_compliance_checks.sql
```

### 3. Configure dbt

```bash
cd dbt
pip install "dbt-snowflake~=1.8.0"
cp profiles.yml.example ~/.dbt/profiles.yml
# Edit ~/.dbt/profiles.yml with your Snowflake credentials

dbt deps           # install packages (dbt_utils, dbt_expectations, elementary)
dbt debug          # verify connection
dbt seed           # load reference data (data domains, country/GDPR mapping)
dbt run            # run all models
dbt test           # run data quality tests
```

See [docs/runbooks/onboarding.md](docs/runbooks/onboarding.md) for the full developer
onboarding guide including RSA key-pair setup and per-developer schema isolation.

### 4. Apply Power BI row-level security

After dbt has created the gold tables, apply Snowflake RLS and masking policies:

```bash
snowsql -f powerbi/row_level_security/rls_snowflake_setup.sql
```

Then follow [powerbi/saml_oauth_setup.md](powerbi/saml_oauth_setup.md) to configure
the Azure AD app registration and Snowflake OAuth security integration.

---

## Data Model

### Silver Layer (FOUNDATION_DB) — conformed entities

| Model | Grain | Source |
|-------|-------|--------|
| `slv_customers` | One row per customer | SQL Server via Fivetran |
| `slv_orders` | One row per order | SQL Server via Fivetran |
| `slv_order_items` | One row per order line item | SQL Server via Fivetran |
| `slv_products` | One row per product | SQL Server via Fivetran |
| `slv_events` | One row per web/app event | S3 via Snowpipe |

### Gold Layer (ANALYTICS_DB) — curated data products

| Model | Domain | Description |
|-------|--------|-------------|
| `gld_customer_360` | Marketing | Customer profile + lifetime order metrics + RFM segmentation |
| `gld_revenue_summary` | Finance | Daily revenue roll-up by product category, country, and channel |
| `gld_product_performance` | Operations | Product scorecard: velocity, margin, return rate, fulfilment speed |

Gold models include a `DATA_DOMAIN` column used as the anchor for Snowflake Row Access
Policies. Power BI users see only the rows for their AD group's domain.

### Reference Data (FOUNDATION_DB.REFERENCE) — seed tables

| Seed | Description |
|------|-------------|
| `ref_data_domains` | Business domain definitions, owning teams, and Power BI role mappings |
| `ref_country_regions` | ISO 3166-1 country → region, GDPR/CCPA applicability, and data residency zone |

---

## Security Model

This implementation enforces **least-privilege RBAC** aligned to the CIS Snowflake Foundations Benchmark:

| Role | Purpose |
|------|---------|
| `LOADER_ROLE` | Service account for data ingestion (Fivetran / ADF / Snowpipe) |
| `TRANSFORMER_ROLE` | dbt service account — reads bronze, writes silver/gold |
| `DATA_ENGINEER_ROLE` | Platform engineers — full read across all layers, DDL in DEV_DB |
| `DATA_ANALYST_ROLE` | Business analysts — read gold + silver |
| `DATA_SCIENTIST_ROLE` | ML/DS team — read gold + silver, can create dev schemas |
| `POWERBI_ROLE` | Power BI gateway service account — read all of ANALYTICS_DB |
| `POWERBI_MARKETING_ROLE` | PBI users in AD group `PBI_MARKETING` (RLS: Marketing rows only) |
| `POWERBI_FINANCE_ROLE` | PBI users in AD group `PBI_FINANCE` (RLS: Finance rows only) |
| `POWERBI_OPERATIONS_ROLE` | PBI users in AD group `PBI_OPERATIONS` (RLS: Operations rows only) |

Key controls applied at every layer:

- **Network policies** — IP allowlisting per service account and per human user population (CIS 2.1/2.2)
- **Password policy** — 14-char minimum, 90-day rotation, 5-attempt lockout (CIS 1.3)
- **Session policy** — 60-minute idle timeout for users, 30-minute for privileged accounts (CIS 1.4)
- **SCIM provisioning** — Azure AD lifecycle management for automated deprovisioning (CIS 1.6)
- **Key-pair authentication** — all service accounts; no passwords (CIS 1.5)
- **Managed access schemas** — prevents schema owners from escalating object access (CIS 3.5)
- **Dynamic column masking** — PII columns (email, phone, name, DOB) masked per role (CIS 4.3)
- **Row access policies** — domain isolation, tenant isolation, regional data residency (CIS 4.4)
- **Object tags** — PII category and compliance scope (`GDPR`, `PCI_DSS`, etc.) on all sensitive columns
- **Security alerts** — ACCOUNTADMIN usage, network policy changes, role/user changes (CIS 5.3/6.x)

See [docs/architecture/security-model.md](docs/architecture/security-model.md) for the full model
and [docs/architecture/cis_benchmark_compliance.md](docs/architecture/cis_benchmark_compliance.md)
for the complete CIS control mapping.

---

## Multi-Account Architecture

For organisations that require environment isolation, business unit separation, or cross-region
disaster recovery, this repo includes a multi-account layer under `infrastructure/snowflake/multi_account/`:

| Script | Purpose |
|--------|---------|
| `01_organizations_setup.sql` | Snowflake Organizations setup, account provisioning, org-level cost views |
| `02_cross_account_sharing.sql` | Secure Data Sharing between accounts (gold tables, reference data, monitoring) |
| `03_account_replication.sql` | Failover Groups for cross-region HA/DR (RPO: 10 min, RTO: ~5 min) |

Common topologies:

- **Account-per-environment** (recommended): `<ORG>-DEV` / `<ORG>-STAGING` / `<ORG>-PROD`
- **Account-per-BU**: `<ORG>-FINANCE` / `<ORG>-MARKETING` / `<ORG>-SHARED-SERVICES`
- **Hub-and-spoke**: PROD hub shares gold data to dedicated Analytics and Data Science accounts

See [docs/architecture/multi_account_architecture.md](docs/architecture/multi_account_architecture.md)
for a detailed guide on choosing a topology and configuring each pattern.

---

## CI/CD

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `dbt-ci.yml` | Pull request to `main` | Compile, SQLFluff lint, run modified models (`state:modified+`), test, clean up ephemeral CI schema. Publishes `dbt-manifest-prod` artifact for state comparison. |
| `dbt-production.yml` | Nightly at 04:00 UTC | Seed reference data → source freshness check → bronze+silver run → silver test gate → gold run → gold test → SCD2 snapshots → Slack notification. |
| `snowflake-deploy.yml` | Push to `main` (infra path) or manual | Credential scan, deploy changed infrastructure SQL scripts. Manual dispatch allows targeting a specific environment and script. |

GitHub Secrets required:

| Secret | Used by |
|--------|---------|
| `SNOWFLAKE_ACCOUNT` | All workflows |
| `SNOWFLAKE_CI_USER` | dbt-ci |
| `SNOWFLAKE_PRIVATE_KEY_CONTENT` | dbt-ci (base64-encoded PEM) |
| `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` | dbt-ci, dbt-production |
| `SNOWFLAKE_PROD_PRIVATE_KEY` | dbt-production |
| `SNOWFLAKE_SYSADMIN_PRIVATE_KEY` | snowflake-deploy |
| `SLACK_WEBHOOK_URL` | dbt-production |

---

## Data Quality

All models include dbt tests for:
- `not_null` and `unique` on all primary keys
- `relationships` (referential integrity across layers)
- `accepted_values` on all categorical/status columns
- `dbt_utils.expression_is_true` on financial amounts (non-negative)
- `dbt_expectations.expect_column_values_to_be_between` on timestamps and rates

Custom singular tests:
- `test_gold_revenue_no_negative` — no negative revenue in the gold finance layer
- `test_silver_no_orphan_orders` — orphan order rate below 1%
- `test_customer_360_completeness` — all active customers present in the gold 360 view

Test failures are stored in `MONITORING_DB.DATA_QUALITY` and trigger the
`ALERT_DBT_TEST_FAILURES` Snowflake alert within 30 minutes.

---

## CIS Snowflake Benchmark Compliance

This template is designed to satisfy all applicable controls in the
**CIS Snowflake Security Foundations Benchmark v1.0**. The implementation status of each
control is documented in [docs/architecture/cis_benchmark_compliance.md](docs/architecture/cis_benchmark_compliance.md).

Run the compliance check script after bootstrapping to verify your posture:

```bash
snowsql -a <your-account> \
  -r ACCOUNTADMIN \
  -f infrastructure/snowflake/security/06_cis_compliance_checks.sql
```

The final query in the script returns a single-row dashboard showing the count of gaps
across the key CIS sections. All values should be 0.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branching strategy, PR process, naming
conventions, and SQL style guide.

See [docs/runbooks/environment_promotion.md](docs/runbooks/environment_promotion.md)
for the full process of promoting changes from development through to production.

Credentials must **never** be committed — the `snowflake-deploy.yml` workflow includes
a credential scan step that fails the build on any suspicious patterns. Use `<PLACEHOLDER>`
tokens for any org-specific values in SQL scripts.
