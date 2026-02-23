# Contributing Guide

## Branching Strategy

This repo uses **GitHub Flow**:

```
main
 └── feature/<description>   (all development work)
 └── fix/<description>        (bug fixes)
 └── infra/<description>      (Snowflake infrastructure changes)
```

- All merges to `main` require a Pull Request
- `main` is protected — direct pushes are blocked
- CI must pass before merge

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(silver): add slv_products model with category normalisation
fix(gold): correct null handling in gld_revenue_summary margin calc
infra(security): add masking policy for date_of_birth column
docs(runbook): add cost spike incident playbook
chore(deps): bump dbt-snowflake to 1.8.3
```

## dbt Conventions

### Naming

| Layer | Prefix | Example |
|-------|--------|---------|
| Bronze | `brz_` | `brz_sqlserver_customers` |
| Silver | `slv_` | `slv_customers` |
| Gold | `gld_` | `gld_customer_360` |
| Snapshot | `snp_` | `snp_customers` |

### Model Requirements

Every model must have:
- A `config` block with `materialized`, `tags`, and `meta.owner`
- A header comment explaining purpose, grain, and any PII present
- A corresponding entry in `_schema.yml` with `description` for the model and all columns
- Tests on all primary keys (`not_null` + `unique`) and foreign keys (`relationships`)

### SQL Style

- All SQL keywords: `UPPER CASE`
- All identifiers: `lower_case` within SELECT; `UPPER_CASE` in DDL
- One column per line in SELECT lists
- CTEs over subqueries; CTE names reflect their purpose
- Use `{{ ref() }}` for model references, `{{ source() }}` for raw sources
- Never use `SELECT *` in silver or gold models — explicit column lists only
- Use the macro library (`audit_columns()`, `incremental_date_filter()`, etc.)

## Infrastructure SQL Conventions

- Every script must have a header comment with purpose, required role, and run-order note
- All `CREATE` statements use `IF NOT EXISTS`
- Placeholder tokens use `<UPPER_SNAKE_CASE>` format (e.g. `<YOUR_BUCKET_NAME>`)
- Never hardcode passwords, IPs, or ARNs — use placeholder tokens
- Scripts are idempotent (safe to re-run)

## Pull Request Checklist

Before requesting review, verify:

- [ ] CI pipeline passes (`dbt compile`, `dbt run`, `dbt test`)
- [ ] `_schema.yml` updated for any new or modified models
- [ ] PII columns tagged with `meta.pii_category` in schema YAML
- [ ] `CONTRIBUTING.md` conventions followed
- [ ] No hardcoded credentials, account names, or real IP addresses in SQL files
- [ ] New infrastructure scripts are idempotent (`CREATE IF NOT EXISTS`)
- [ ] PR description explains *why* the change is needed (not just *what*)

## Security Rules (Non-Negotiable)

- **Never** commit `.env` files, private keys, or credentials
- **Never** hardcode passwords in SQL or YAML files
- **Never** disable pre-commit hooks (`--no-verify`)
- Any accidental secret commit: rotate the secret immediately, then open an incident
