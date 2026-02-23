# Snowflake Security Model

## Principles

1. **Least Privilege** — every role and user has only the permissions needed for its function
2. **Separation of Duties** — ACCOUNTADMIN, SECURITYADMIN, SYSADMIN are distinct personas
3. **Defence in Depth** — network → authentication → authorisation → data masking → row filtering
4. **No Shared Credentials** — every service account uses RSA key-pair auth; no passwords
5. **Auditability** — all access is logged; ACCOUNT_USAGE views surfaced via MONITORING_DB

---

## Role Hierarchy

```
ACCOUNTADMIN  (Snowflake built-in — strictly limited; use only for account-level tasks)
│
├── SECURITYADMIN  (manages roles, grants, security integrations, network policies)
│   └── USERADMIN  (creates/modifies users only)
│
└── SYSADMIN  (creates databases, warehouses, schemas, tables)
    │
    ├── LOADER_ROLE            → Fivetran, ADF, Snowpipe (write RAW_DB)
    ├── TRANSFORMER_ROLE       → dbt service account (read RAW; write FOUNDATION + ANALYTICS)
    ├── DATA_ENGINEER_ROLE     → Platform engineers (read all; DDL in DEV_DB)
    │   ├── DATA_ANALYST_ROLE  → Business analysts (read FOUNDATION + ANALYTICS)
    │   └── DATA_SCIENTIST_ROLE→ ML team (read all; create in DEV_DB)
    │
    └── POWERBI_ROLE           → Power BI gateway service account (read ANALYTICS)
        ├── POWERBI_MARKETING_ROLE   → AD group PBI_MARKETING (ANALYTICS.MARKETING schema + RLS)
        ├── POWERBI_FINANCE_ROLE     → AD group PBI_FINANCE (ANALYTICS.FINANCE schema + RLS)
        └── POWERBI_OPERATIONS_ROLE  → AD group PBI_OPERATIONS (ANALYTICS.OPERATIONS schema + RLS)
```

### Why roles roll up to SYSADMIN

All custom roles must roll up to SYSADMIN so that account administrators can always
recover access. This is a Snowflake best practice that prevents privilege orphaning.

---

## Authentication Controls

| Principal | Auth Method | MFA | Password Policy |
|-----------|------------|-----|-----------------|
| Human users (SSO) | Azure AD SAML 2.0 | Enforced by Azure AD Conditional Access | No Snowflake password |
| Service accounts | RSA Key-pair (2048-bit minimum) | N/A | No password set |
| Emergency break-glass | Snowflake password (ACCOUNTADMIN only) | MFA enforced | CORPORATE_PASSWORD_POLICY |

### Key Rotation

RSA private keys for service accounts should be rotated every **90 days**.
Use Snowflake's key-pair rotation feature:

```sql
-- Add a secondary key (zero-downtime rotation)
ALTER USER SVC_DBT_TRANSFORMER SET RSA_PUBLIC_KEY_2 = '<new_public_key>';
-- After updating the application to use the new key, remove the old one:
ALTER USER SVC_DBT_TRANSFORMER UNSET RSA_PUBLIC_KEY;
```

---

## Network Controls

Two network policies restrict access by source IP:

- **CORPORATE_NETWORK_POLICY** — human users; allows office + VPN egress IPs
- **SERVICE_ACCOUNT_NETWORK_POLICY** — tighter; only specific integration tool IPs

Applied at user level (overrides account-level policy for service accounts).
See [infrastructure/snowflake/account_setup/05_network_policies.sql](../../infrastructure/snowflake/account_setup/05_network_policies.sql).

---

## Data Protection Controls

### Dynamic Column Masking

PII columns are masked at query time based on `CURRENT_ROLE()`:

| Role | EMAIL | PHONE | FULL_NAME | DATE_OF_BIRTH |
|------|-------|-------|-----------|---------------|
| ACCOUNTADMIN / SYSADMIN / DATA_ENGINEER / TRANSFORMER | Full | Full | Full | Full |
| DATA_ANALYST / DATA_SCIENTIST | `j***@domain.com` | `+1-555-***-****` | `J***` | `YYYY-01-01` |
| POWERBI_* | `***@***.***` | `***-***-****` | `***` | `NULL` |

Masking policies defined in `infrastructure/snowflake/security/03_column_masking_policies.sql`.
Applied to production tables via `powerbi/row_level_security/rls_snowflake_setup.sql`.

### Row Access Policies

Three row access policies are defined:

| Policy | Applies To | Behaviour |
|--------|-----------|-----------|
| `DOMAIN_ACCESS_POLICY` | Gold tables with `DATA_DOMAIN` column | Filters rows to the role's permitted domains |
| `TENANT_ISOLATION_POLICY` | Multi-tenant tables | Each user sees only their mapped tenant |
| `REGION_RESIDENCY_POLICY` | Regional data tables | EU users see only EU/GLOBAL data |

### Object Tags

All tables and PII columns should be tagged using:
- `DATA_SENSITIVITY`: PUBLIC / INTERNAL / CONFIDENTIAL / RESTRICTED
- `PII_CATEGORY`: EMAIL / PHONE / NAME / DATE_OF_BIRTH / etc.
- `COMPLIANCE_SCOPE`: GDPR / CCPA / PCI_DSS / HIPAA

Tags drive the data catalogue view in `MONITORING_DB.AUDIT.VW_TAG_INVENTORY`.

---

## Audit and Compliance

All events are logged in `SNOWFLAKE.ACCOUNT_USAGE` (retained 365 days).
Key views in `MONITORING_DB.AUDIT`:

| View | Purpose |
|------|---------|
| `VW_LOGIN_HISTORY` | All login attempts with failure flags |
| `VW_RECENT_FAILED_LOGINS` | Failed logins in last 24h (alert trigger) |
| `VW_GRANT_HISTORY` | All GRANT/REVOKE statements |
| `VW_PII_TABLE_ACCESS` | Who accessed PII-bearing tables |
| `VW_MASKING_POLICY_COVERAGE` | Which columns have masking applied |
| `VW_ROW_ACCESS_POLICY_COVERAGE` | Which tables have row filters |
| `VW_TAG_INVENTORY` | Full data classification catalogue |

---

## Access Review Process

1. **Monthly**: Review `VW_RECENT_FAILED_LOGINS` for brute-force patterns
2. **Quarterly**: Full access review — run `VW_USER_ROLE_GRANTS` and compare to HR records
3. **Quarterly**: Rotate service account RSA keys
4. **Annually**: Full privilege audit — run `VW_ROLE_PRIVILEGE_GRANTS` and remove stale grants
5. **On offboarding**: Immediately run `DISABLE USER <user>` then schedule deletion after 30 days
