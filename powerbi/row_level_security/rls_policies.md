# Row-Level Security Policy Reference

This document maps Azure AD groups to Snowflake roles and defines which data each
Power BI user population can access.

---

## AD Group → Role → Data Access Matrix

| Azure AD Group | Snowflake Role | Database | Schemas Accessible | Row Filter |
|---|---|---|---|---|
| `PBI_MARKETING` | `POWERBI_MARKETING_ROLE` | ANALYTICS_DB | MARKETING | `data_domain = 'MARKETING'` |
| `PBI_FINANCE` | `POWERBI_FINANCE_ROLE` | ANALYTICS_DB | FINANCE | `data_domain = 'FINANCE'` |
| `PBI_OPERATIONS` | `POWERBI_OPERATIONS_ROLE` | ANALYTICS_DB | OPERATIONS | `data_domain IN ('OPERATIONS','SUPPLY_CHAIN')` |
| `PBI_EXECUTIVE` | `POWERBI_ROLE` (full) | ANALYTICS_DB | ALL | No row filter |
| `DATA_ANALYSTS` | `DATA_ANALYST_ROLE` | FOUNDATION_DB + ANALYTICS_DB | ALL | No row filter |

---

## Column Masking Behaviour by Role

| Column | Column Type | `DATA_ENGINEER_ROLE` | `DATA_ANALYST_ROLE` | `POWERBI_*_ROLE` |
|--------|-------------|----------------------|---------------------|------------------|
| `email_address` | PII - EMAIL | Full | `j***@domain.com` | `***@***.***` |
| `full_name` | PII - NAME | Full | `J***` | `***` |
| `phone_number` | PII - PHONE | Full | `+1-555-***-****` | `***-***-****` |
| `date_of_birth` | PII - DOB | Full date | Year only (`YYYY-01-01`) | `NULL` |

---

## Enforcement Layers

1. **Network Policy** (IP-based) — blocks connections from non-approved IPs
2. **Role-Based Access** — POWERBI_MARKETING_ROLE can only `SELECT` on `ANALYTICS_DB.MARKETING.*`
3. **Row Access Policy** — filters rows by `data_domain` at query time
4. **Column Masking Policy** — masks PII columns based on `CURRENT_ROLE()`
5. **Power BI Report RLS** — DAX filters as defence-in-depth (does not replace Snowflake RLS)

---

## Adding a New Power BI User Population

1. Create Azure AD group (e.g. `PBI_SALES`)
2. Create Snowflake role:
   ```sql
   USE ROLE SECURITYADMIN;
   CREATE ROLE IF NOT EXISTS POWERBI_SALES_ROLE;
   GRANT ROLE POWERBI_SALES_ROLE TO ROLE POWERBI_ROLE;
   GRANT USAGE ON WAREHOUSE ANALYTICS_WH TO ROLE POWERBI_SALES_ROLE;
   GRANT USAGE ON DATABASE ANALYTICS_DB TO ROLE POWERBI_SALES_ROLE;
   GRANT USAGE ON SCHEMA ANALYTICS_DB.OPERATIONS TO ROLE POWERBI_SALES_ROLE;
   GRANT SELECT ON ALL TABLES IN SCHEMA ANALYTICS_DB.OPERATIONS TO ROLE POWERBI_SALES_ROLE;
   GRANT SELECT ON FUTURE TABLES IN SCHEMA ANALYTICS_DB.OPERATIONS TO ROLE POWERBI_SALES_ROLE;
   ```
3. Update `DOMAIN_ACCESS_POLICY` in `04_row_access_policies.sql` to include the new role
4. Configure Azure AD token claim to map the new AD group to `POWERBI_SALES_ROLE`
5. Apply RLS and masking policies to any new gold tables via `rls_snowflake_setup.sql`
6. Update this document

---

## Quarterly Access Review Checklist

- [ ] Run `SELECT * FROM MONITORING_DB.AUDIT.VW_USER_ROLE_GRANTS` and confirm no unexpected grants
- [ ] Verify AD group memberships match expected headcount per department
- [ ] Review `VW_PII_TABLE_ACCESS` for any unexpected PII access patterns
- [ ] Confirm all new gold tables have row access and masking policies applied
- [ ] Check for any users with `ACCOUNTADMIN` or `SYSADMIN` that shouldn't have it
- [ ] Verify service account passwords haven't been set (key-pair auth only)
