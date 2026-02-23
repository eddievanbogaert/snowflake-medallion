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
│   └── workflows/           # CI/CD pipelines (dbt CI, Snowflake deploy)
├── docs/
│   ├── architecture/        # Architecture decisions and diagrams
│   └── runbooks/            # Operational runbooks
├── infrastructure/
│   └── snowflake/
│       ├── account_setup/     # Databases, warehouses, roles, users
│       ├── security/          # Masking policies, row access, tags
│       ├── monitoring/        # Resource monitors, alerts, audit logs
│       ├── integrations/      # S3 storage integration, SQL Server
│       └── backup/            # Time travel, cross-region replication
├── dbt/
│   ├── models/
│   │   ├── bronze/            # Raw ingestion models
│   │   ├── silver/            # Cleansed / validated models
│   │   └── gold/              # Curated data product models
│   ├── macros/                # Shared Jinja macros
│   ├── snapshots/             # SCD Type 2 snapshots
│   └── tests/                 # Singular + generic data quality tests
├── powerbi/
│   ├── saml_oauth_setup.md    # SSO integration guide
│   └── row_level_security/    # RLS policy templates
└── scripts/
    ├── setup/                 # Bootstrap & validation scripts
    └── utilities/             # Cost reports, dev clone helpers
```

## Quick Start

### Prerequisites

| Tool | Version |
|------|---------|
| Snowflake account | Enterprise edition or higher |
| Python | 3.11+ |
| dbt-snowflake | 1.8+ |
| AWS CLI | 2.x (if using S3 integration) |
| Azure CLI | (if using Azure AD / SAML SSO) |

### 1. Clone and configure

```bash
git clone https://github.com/your-org/snowflake-medallion.git
cd snowflake-medallion
cp .env.example .env
# Edit .env with your environment-specific values
```

### 2. Bootstrap Snowflake infrastructure

Run scripts in order using an `ACCOUNTADMIN` session:

```bash
# Order matters — run as ACCOUNTADMIN
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

# External integrations (requires AWS/Azure pre-config)
snowsql -f infrastructure/snowflake/integrations/01_storage_integration_s3.sql
snowsql -f infrastructure/snowflake/integrations/02_external_stages.sql
snowsql -f infrastructure/snowflake/integrations/03_sqlserver_integration.sql
```

Or use the bootstrap script:

```bash
chmod +x scripts/setup/bootstrap.sh
./scripts/setup/bootstrap.sh --env dev
```

### 3. Configure dbt

```bash
cd dbt
pip install dbt-snowflake
cp profiles.yml.example ~/.dbt/profiles.yml
# Edit with your Snowflake credentials

dbt deps        # install packages
dbt debug       # verify connection
dbt run         # run all models
dbt test        # run data quality tests
```

See [docs/runbooks/onboarding.md](docs/runbooks/onboarding.md) for the full developer onboarding guide.

## Security Model

This implementation enforces **least-privilege RBAC** with the following principals:

| Role | Purpose |
|------|---------|
| `LOADER_ROLE` | Service account for data ingestion (Fivetran / ADF / Snowpipe) |
| `TRANSFORMER_ROLE` | dbt service account — reads bronze, writes silver/gold |
| `DATA_ENGINEER_ROLE` | Platform engineers — full read, limited write |
| `DATA_ANALYST_ROLE` | Business analysts — read gold + silver |
| `DATA_SCIENTIST_ROLE` | ML/DS team — read gold + silver, can create dev schemas |
| `POWERBI_ROLE` | Power BI gateway service account |
| `POWERBI_MARKETING_ROLE` | PBI users in Marketing AD group (RLS filtered) |
| `POWERBI_FINANCE_ROLE` | PBI users in Finance AD group (RLS filtered) |

See [docs/architecture/security-model.md](docs/architecture/security-model.md) for full details.

## Data Quality

All models include dbt tests for:
- `not_null` on primary and foreign keys
- `unique` on natural keys
- `accepted_values` on categorical fields
- `relationships` for referential integrity across layers
- Custom singular tests for business rules

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branching strategy, PR process, and coding standards.
Secrets and credentials must **never** be committed. The pre-commit hook in `.github/` enforces this.

## License

MIT — see [LICENSE](LICENSE).
