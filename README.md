# Snowflake Medallion Architecture

An enterprise-grade Snowflake data platform reference implementation featuring a
medallion (Bronze → Silver → Gold) architecture with full security, observability,
and governance controls.

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

## Repository Structure

```
snowflake-medallion/
├── .github/
│   └── workflows/
│       ├── dbt-ci.yml              # PR validation: compile, lint, run, test
│       ├── dbt-production.yml      # Nightly production run with Slack alerts
│       └── snowflake-deploy.yml    # Infrastructure change deployment
├── docs/
│   ├── architecture/
│   │   └── security-model.md       # RBAC hierarchy, masking, RLS, audit
│   └── runbooks/
│       ├── onboarding.md           # New developer setup guide
│       └── incident-response.md    # 5 incident playbooks (data loss, pipeline, etc.)
├── infrastructure/
│   └── snowflake/
│       ├── account_setup/          # Databases, warehouses, roles, users, network policies
│       ├── security/               # Object tags, data classification, masking, row access
│       ├── monitoring/             # Resource monitors, audit log views, alerting
│       ├── integrations/           # S3 storage integration, Snowpipe, SQL Server patterns
│       └── backup/                 # Time travel config, cross-region replication
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml.example        # Connection template (copy to ~/.dbt/profiles.yml)
│   ├── packages.yml                # dbt_utils, dbt_expectations, audit_helper, elementary
│   ├── models/
│   │   ├── bronze/
│   │   │   ├── sources.yml         # Source definitions with freshness checks
│   │   │   ├── sqlserver/          # brz_sqlserver_{customers,orders,order_items,products}
│   │   │   └── s3/                 # brz_s3_{events,transactions}
│   │   ├── silver/
│   │   │   ├── customers/          # slv_customers
│   │   │   ├── orders/             # slv_orders, slv_order_items
│   │   │   ├── products/           # slv_products
│   │   │   └── events/             # slv_events
│   │   └── gold/
│   │       ├── marketing/          # gld_customer_360
│   │       ├── finance/            # gld_revenue_summary
│   │       └── operations/         # gld_product_performance
│   ├── macros/                     # audit_columns, generate_schema_name, safe_cast_*, etc.
│   ├── snapshots/                  # snp_customers (SCD Type 2)
│   └── tests/singular/             # Business-rule tests across all layers
├── powerbi/
│   ├── saml_oauth_setup.md         # Azure AD SSO + OAuth integration guide
│   └── row_level_security/
│       ├── rls_snowflake_setup.sql # Applies row access + masking policies to gold tables
│       └── rls_policies.md         # AD group → role → data access matrix
└── scripts/
    ├── setup/
    │   └── bootstrap.sh            # Ordered, role-aware execution of all infra scripts
    └── utilities/
        ├── clone_for_dev.sh        # Zero-copy dev/test clones from production schemas
        └── cost_report.sql         # Credit consumption and storage cost queries
```

## Quick Start

### Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Snowflake account | Enterprise edition or higher | Business Critical for failover groups |
| Python | 3.11+ | Use `pyenv` to manage versions |
| dbt-snowflake | 1.8.x | See `dbt/packages.yml` for exact constraint |
| SnowSQL | 1.2.x | For running infrastructure scripts |
| AWS CLI | 2.x | Required for S3 storage integration setup |
| Azure CLI | latest | Required for Azure AD / SAML SSO configuration |

### 1. Clone and configure

```bash
git clone https://github.com/your-org/snowflake-medallion.git
cd snowflake-medallion
cp .env.example .env
# Edit .env with your environment-specific values
```

### 2. Bootstrap Snowflake infrastructure

Each script specifies its required role in the header comment. The bootstrap script
handles role switching automatically, or you can run them manually:

```bash
# Each script uses the appropriate least-privilege role (see script headers)
snowsql -f infrastructure/snowflake/account_setup/01_databases.sql
snowsql -f infrastructure/snowflake/account_setup/02_warehouses.sql
snowsql -f infrastructure/snowflake/account_setup/03_roles.sql
snowsql -f infrastructure/snowflake/account_setup/04_users.sql
snowsql -f infrastructure/snowflake/account_setup/05_network_policies.sql

# Security controls
snowsql -f infrastructure/snowflake/security/01_object_tags.sql
snowsql -f infrastructure/snowflake/security/02_data_classification.sql
snowsql -f infrastructure/snowflake/security/03_column_masking_policies.sql
snowsql -f infrastructure/snowflake/security/04_row_access_policies.sql

# Monitoring
snowsql -f infrastructure/snowflake/monitoring/01_resource_monitors.sql
snowsql -f infrastructure/snowflake/monitoring/02_audit_logging.sql
snowsql -f infrastructure/snowflake/monitoring/03_alerts.sql

# External integrations (requires AWS/Azure pre-configuration — see script headers)
snowsql -f infrastructure/snowflake/integrations/01_storage_integration_s3.sql
snowsql -f infrastructure/snowflake/integrations/02_external_stages.sql
snowsql -f infrastructure/snowflake/integrations/03_sqlserver_integration.sql
```

Or use the bootstrap script, which handles ordering and role switching:

```bash
chmod +x scripts/setup/bootstrap.sh
./scripts/setup/bootstrap.sh --env dev
```

### 3. Configure dbt

```bash
cd dbt
pip install "dbt-snowflake~=1.8.0"
cp profiles.yml.example ~/.dbt/profiles.yml
# Edit ~/.dbt/profiles.yml with your Snowflake credentials

dbt deps        # install packages (dbt_utils, dbt_expectations, elementary)
dbt debug       # verify connection
dbt run         # run all models
dbt test        # run data quality tests
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

## Security Model

This implementation enforces **least-privilege RBAC** with the following principals:

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
- **Network policies** — IP allowlisting per service account and per human user population
- **Key-pair authentication** — all service accounts; no passwords
- **Dynamic column masking** — PII columns (email, phone, name, DOB) masked per role
- **Row access policies** — domain isolation, tenant isolation, regional data residency
- **Object tags** — PII category and compliance scope (`GDPR`, `PCI_DSS`, etc.) on all sensitive columns

See [docs/architecture/security-model.md](docs/architecture/security-model.md) for the full model.

## CI/CD

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `dbt-ci.yml` | Pull request to `main` | Compile, SQLFluff lint, run modified models (`state:modified+`), test, clean up ephemeral CI schema |
| `dbt-production.yml` | Nightly at 04:00 UTC | Source freshness check → bronze+silver run → silver test gate → gold run → gold test → SCD2 snapshots → Slack notification |
| `snowflake-deploy.yml` | Push to `main` (infra path) or manual | Credential scan, deploy changed infrastructure SQL scripts |

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branching strategy, PR process, naming
conventions, and SQL style guide. Credentials must **never** be committed — the
`snowflake-deploy.yml` workflow includes a credential scan step that fails the build
on any suspicious patterns.
