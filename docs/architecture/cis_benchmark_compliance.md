# CIS Snowflake Foundations Benchmark Compliance

This document maps every control in the **CIS Snowflake Security Foundations Benchmark v1.0** to the implementation in this repository. It serves as an evidence trail for internal audits and security reviews.

---

## How to use this document

- **Status** — whether the control is fully implemented (`Implemented`), partially implemented (`Partial`), or requires post-deployment configuration (`Manual`).
- **Implementation** — which file(s) satisfy the control.
- Run `infrastructure/snowflake/security/06_cis_compliance_checks.sql` against your account to verify the current posture programmatically.

---

## Section 1: Identity and Access Management

| Control | Description | Status | Implementation |
|---------|-------------|--------|----------------|
| **CIS 1.1** | Ensure MFA is enforced for all non-service human users | Implemented | `account_setup/08_authentication_policies.sql` — `HUMAN_AUTH_POLICY` restricts humans to SAML SSO (MFA enforced by Azure AD Conditional Access); `SERVICE_AUTH_POLICY` restricts service users to key-pair. Monitored via `MONITORING_DB.AUDIT.VW_LOGIN_HISTORY` (flag: `NO_MFA_WARNING`) and the Trust Center Security Essentials scanner. |
| **CIS 1.2** | Ensure SSO is configured for user authentication | Implemented | `powerbi/saml_oauth_setup.md` — SAML 2.0 security integration with Azure AD. Service accounts use RSA key-pair, not password. |
| **CIS 1.3** | Ensure a strong password policy is applied | Implemented | `account_setup/06_password_policies.sql` — `STRONG_PASSWORD_POLICY`: min 14 chars, upper/lower/digit/special required, 90-day rotation, 5-attempt lockout, 24-password history. |
| **CIS 1.4** | Ensure session timeout is configured | Implemented | `account_setup/06_password_policies.sql` — `STANDARD_SESSION_POLICY` (60-min idle), `PRIVILEGED_SESSION_POLICY` (30-min idle for admins). Applied at account level. |
| **CIS 1.5** | Ensure service accounts use key-pair authentication | Implemented | `account_setup/04_users.sql` — all service accounts created with `TYPE = SERVICE` and RSA public key; `08_authentication_policies.sql` blocks any non-key-pair method. Verified by `06_cis_compliance_checks.sql` (keys off `USERS.TYPE`). |
| **CIS 1.6** | Ensure SCIM is used for user lifecycle management | Implemented | `account_setup/07_scim_integration.sql` — Azure AD SCIM integration for automated provisioning/deprovisioning. `VW_SCIM_VS_MANUAL_USERS` audits manually created accounts. |

### Notes on MFA enforcement

Snowflake itself cannot enforce MFA for SAML-based login — that is the IdP's responsibility. Verify in Azure AD that:

1. A Conditional Access policy requires MFA for the Snowflake Enterprise Application.
2. The policy covers all user groups, not just admins.
3. Legacy authentication (basic auth) is blocked for Snowflake.

---

## Section 2: Network Controls

| Control | Description | Status | Implementation |
|---------|-------------|--------|----------------|
| **CIS 2.1** | Ensure a network policy restricts source IP ranges | Implemented | `account_setup/05_network_policies.sql` — `CORPORATE_NETWORK_POLICY` for human users, `SERVICE_ACCOUNT_NETWORK_POLICY` for service accounts. Apply account-level policy by uncommenting the `ALTER ACCOUNT` line. |
| **CIS 2.2** | Ensure service accounts have individual restrictive network policies | Implemented | Same file — each service account is individually assigned `SERVICE_ACCOUNT_NETWORK_POLICY`, which allows only specific integration tool IPs. |
| **CIS 2.3** | Ensure private connectivity is used where available | Manual | Snowflake AWS PrivateLink or Azure Private Link is recommended for production. Configure at the Snowflake account level; this template does not provision VPC/VNet resources. See [Snowflake PrivateLink docs](https://docs.snowflake.com/en/user-guide/admin-security-privatelink). |

---

## Section 3: Access Controls

| Control | Description | Status | Implementation |
|---------|-------------|--------|----------------|
| **CIS 3.1** | Ensure no privileges are granted directly to users (use roles) | Implemented | Enforced at the platform level — Snowflake does not support granting object privileges directly to users. `GRANTS_TO_USERS` contains only role-to-user grants; direct object grants are architecturally impossible. `06_cis_compliance_checks.sql` verifies that only designated admins hold ACCOUNTADMIN/SECURITYADMIN/SYSADMIN. |
| **CIS 3.2** | Ensure ACCOUNTADMIN is assigned to as few users as possible | Implemented | `account_setup/04_users.sql` — only a single break-glass account holds `ACCOUNTADMIN`. Verified by compliance check. |
| **CIS 3.3** | Ensure ACCOUNTADMIN is not used for day-to-day operations | Implemented | All service accounts and human users operate under functional roles. `monitoring/04_privileged_access_alerts.sql` — `ALERT_ACCOUNTADMIN_USAGE` fires within 15 minutes of any non-read-only ACCOUNTADMIN query. |
| **CIS 3.4** | Ensure SECURITYADMIN and SYSADMIN are held by separate users | Implemented | `account_setup/04_users.sql` — separation of duty enforced. Compliance check queries `GRANTS_TO_USERS` for overlap. |
| **CIS 3.5** | Ensure managed access schemas are used | Implemented | `security/05_managed_access_schemas.sql` — all production schemas in `RAW_DB`, `FOUNDATION_DB`, `ANALYTICS_DB`, and `MONITORING_DB` have `MANAGED ACCESS` enabled. Prevents schema owners from escalating object access. |

---

## Section 4: Data Protection

| Control | Description | Status | Implementation |
|---------|-------------|--------|----------------|
| **CIS 4.1** | Ensure data at rest encryption is enabled | Implemented | Snowflake encrypts all data at rest by default using AES-256. No configuration required. Consider Tri-Secret Secure (customer-managed key via AWS KMS/Azure Key Vault) for `RESTRICTED` data — requires Business Critical edition. |
| **CIS 4.2** | Ensure data in transit is encrypted | Implemented | Snowflake enforces TLS 1.2+ on all connections. No configuration required. |
| **CIS 4.3** | Ensure dynamic data masking covers all PII columns | Implemented | `security/03_column_masking_policies.sql` — masking policies for email, phone, name, DOB, national ID, card number, and generic `CONFIDENTIAL` columns. Applied by role: admins see full data, analysts see partial, BI users see masked. Gap analysis available in `06_cis_compliance_checks.sql`. |
| **CIS 4.4** | Ensure row access policies are applied for multi-tenant data | Implemented | `security/04_row_access_policies.sql` — three policies: `DOMAIN_ACCESS_POLICY` (BI domain isolation), `TENANT_ISOLATION_POLICY` (multi-tenant), `REGION_RESIDENCY_POLICY` (GDPR residency). |

### Tri-Secret Secure (optional hardening)

For `DATA_SENSITIVITY = RESTRICTED` tables (e.g., HR, legal), consider enabling [Tri-Secret Secure](https://docs.snowflake.com/en/user-guide/security-encryption-manage-customer-key) to require your own KMS key for Snowflake to decrypt data. This means Snowflake cannot access your data without your KMS key being present and reachable.

---

## Section 5: Auditing and Monitoring

| Control | Description | Status | Implementation |
|---------|-------------|--------|----------------|
| **CIS 5.1** | Ensure the edition supports required governance features | Manual | `SNOWFLAKE.ACCOUNT_USAGE` retention is 365 days on **all** editions; what requires Enterprise+ are the governance features this template uses (masking policies, row access policies, tag-based policies). Verify the edition in Snowsight (Admin » Accounts) or `SHOW ORGANIZATION ACCOUNTS` as ORGADMIN. |
| **CIS 5.2** | Ensure failed login monitoring is in place | Implemented | `monitoring/03_alerts.sql` — `ALERT_FAILED_LOGIN_SPIKE` triggers on >5 failed logins in 30 minutes. `monitoring/02_audit_logging.sql` — `VW_RECENT_FAILED_LOGINS` and `VW_LOGIN_HISTORY` with `security_flag` column. |
| **CIS 5.3** | Ensure ACCOUNTADMIN usage is alerted | Implemented | `monitoring/04_privileged_access_alerts.sql` — `ALERT_ACCOUNTADMIN_USAGE` checks every 15 minutes and emails `security-alerts@` on any non-read-only ACCOUNTADMIN execution. |
| **CIS 5.4** | Ensure DDL operations are logged and alerted | Implemented | `monitoring/03_alerts.sql` — `ALERT_UNEXPECTED_DDL` detects CREATE/ALTER/DROP on `ANALYTICS_DB` by non-service accounts. `VW_QUERY_HISTORY` preserves all DDL for 365 days. |
| **CIS 5.5** | Ensure PII column access is audited | Implemented | `monitoring/02_audit_logging.sql` — `VW_PII_TABLE_ACCESS` and `VW_TABLE_ACCESS_HISTORY` expose access patterns for sensitive tables. Requires Snowflake Enterprise for `ACCESS_HISTORY` data. |

---

## Section 6: Incident Response

| Control | Description | Status | Implementation |
|---------|-------------|--------|----------------|
| **CIS 6.1** | Ensure network policy changes are alerted | Implemented | `monitoring/04_privileged_access_alerts.sql` — `ALERT_NETWORK_POLICY_CHANGE` fires within 15 minutes of any CREATE/ALTER/DROP/SET on a network policy. |
| **CIS 6.2** | Ensure user/role creation is monitored | Implemented | `monitoring/04_privileged_access_alerts.sql` — `ALERT_ROLE_GRANT_CHANGE` detects all non-SCIM user, role, grant, and revoke operations. |
| **CIS 6.3** | Ensure break-glass procedures are documented | Implemented | `docs/runbooks/incident-response.md` (Playbook 4) — security incident response with user session audit, account suspension, and escalation steps. `ALERT_BREAKGLASS_LOGIN` fires on break-glass account authentication. |

---

## Continuous scanning — Snowflake Trust Center

`security/07_trust_center.sql` grants Trust Center access and documents enabling
the **CIS Benchmarks scanner package**, which evaluates the published CIS
Snowflake Foundations Benchmark daily and tracks benchmark revisions
automatically. Treat the Trust Center findings as the primary, always-current
CIS posture signal; `06_cis_compliance_checks.sql` remains the template-specific
evidence script (named alerts, schema lists, role names).

---

## Quarterly Compliance Review Checklist

Run the following on the first Monday of each quarter:

```sql
-- 0. Review open Trust Center findings (CIS Benchmarks scanner package)
-- SELECT * FROM SNOWFLAKE.TRUST_CENTER.FINDINGS ORDER BY event_time DESC;

-- 1. Run the full compliance check script
-- (infrastructure/snowflake/security/06_cis_compliance_checks.sql)

-- 2. Review the compliance summary dashboard (last query in the file)

-- 3. Check for orphaned users (no login in 90+ days)
SELECT * FROM MONITORING_DB.AUDIT.VW_SCIM_VS_MANUAL_USERS
WHERE provisioning_method = 'MANUAL_OR_LEGACY';

-- 4. Review all active role grants
SELECT * FROM MONITORING_DB.AUDIT.VW_USER_ROLE_GRANTS
ORDER BY user_name, role_granted;

-- 5. Verify masking policy coverage
SELECT * FROM MONITORING_DB.AUDIT.VW_MASKING_POLICY_COVERAGE
WHERE policy_name IS NULL;   -- columns tagged PII with no masking policy

-- 6. Confirm all security alerts are running
SHOW ALERTS;
-- All security alerts should have state = STARTED
```

---

## Hardening Beyond CIS Baseline

| Recommendation | Priority | Notes |
|---------------|----------|-------|
| Enable Tri-Secret Secure | High for RESTRICTED data | Requires AWS KMS or Azure Key Vault integration. Business Critical edition required. |
| Snowflake Private Link | High for prod | Eliminates public internet routing for all Snowflake traffic. |
| Block secondary roles in session policy | High | Set `BLOCKED_SECONDARY_ROLES = ('ALL')` in session policies to enforce strict single-role sessions. Already applied to `PRIVILEGED_SESSION_POLICY`. Masking/RLS policies use `IS_ROLE_IN_SESSION()` and behave correctly either way. |
| Enable Trust Center scanner packages | High | `security/07_trust_center.sql` — enable CIS Benchmarks + Threat Intelligence scanner packages in Snowsight. |
| Dedicated DR account | Medium | See `infrastructure/snowflake/multi_account/03_account_replication.sql`. |
| SCIM token rotation | Medium | Rotate `AZURE_AD_SCIM` bearer token every 90 days via `SYSTEM$GENERATE_SCIM_ACCESS_TOKEN`. |
| Data Quality SLA alerting | Low | Extend `monitoring/03_alerts.sql` with domain-specific freshness thresholds. |
| Snowflake Horizon Data Governance | Low | Enables automated sensitive data classification across all schemas. |

---

## Government and Public Sector Considerations

Organizations operating under FedRAMP, DoD RMF, or equivalent frameworks should note the following differences from the commercial CIS baseline:

### Authorisation Boundaries

Snowflake offers a FedRAMP-authorised deployment in specific regions:

| Cloud | Region ID | Authorisation Level |
|-------|-----------|---------------------|
| AWS GovCloud | `aws_us_gov_virginia` | FedRAMP High |
| Azure Government Iowa | `azure_usgoviowa` | FedRAMP High |
| Azure Government Virginia | `azure_usgovvirginia` | FedRAMP High |

Accounts in these regions use the `snowflakecomputing.mil` domain. Commercial `snowflakecomputing.com` accounts are NOT within the FedRAMP High authorisation boundary.

### Key Differences from CIS Commercial Baseline

| Area | Commercial | Government |
|------|-----------|------------|
| **Authentication** | Azure AD (commercial) SAML | Azure AD Government (GCC High), Okta FedRAMP, or CAC/PIV via FedRAMP-authorised IdP |
| **Password policy** | NIST-aligned; 90-day rotation | Match agency SSP; some agencies align to NIST 800-63B (risk-based rotation) |
| **Network policy** | Corporate + VPN IPs | Plus agency internal network ranges; PrivateLink strongly recommended |
| **Replication** | Any cross-region | DR target must be within the same authorised boundary (both FedRAMP) |
| **SCIM IdP** | Azure AD / Okta commercial | Azure AD GCC High or other FedRAMP-authorised IdP |
| **Email alerts** | Standard SMTP | FedRAMP-authorised email service (.mil or .gov) |
| **Marketplace** | Available | Limited/unavailable in SnowGov regions — check current listing availability |
| **Cortex AI** | Available (FedRAMP Moderate authorized in commercial US East) | Available in SnowGov FedRAMP High / DoD IL5 environments; model availability varies by region — verify against Snowflake's current authorizations before relying on a specific model |

### NIST SP 800-53 Control Mapping

The following controls from NIST SP 800-53 Rev. 5 are directly addressed by this implementation:

| NIST Control | Description | Implementation |
|-------------|-------------|----------------|
| AC-2 | Account Management | SCIM provisioning (`07_scim_integration.sql`), orphaned user audit |
| AC-3 | Access Enforcement | RBAC (`03_roles.sql`), row access policies |
| AC-5 | Separation of Duties | Managed access schemas (`05_managed_access_schemas.sql`) |
| AC-6 | Least Privilege | Role hierarchy, network policies, managed access |
| AC-7 | Unsuccessful Login Attempts | Password lockout policy (5 retries, 30-min lockout) |
| AC-11 | Session Lock | Session idle timeout policies (60-min / 30-min for privileged) |
| AU-2 | Event Logging | Audit views over `ACCOUNT_USAGE` |
| AU-6 | Audit Review | Security alerts, `VW_PRIVILEGED_OPERATIONS` |
| AU-9 | Protection of Audit Information | Replicated `MONITORING_DB` to governance account (tamper-evident) |
| IA-2 | Identification and Authentication | SAML SSO + MFA via IdP |
| IA-3 | Device Identification | Network policies (IP-based device restriction) |
| SC-8 | Transmission Confidentiality | TLS 1.2+ enforced by Snowflake on all connections |
| SC-28 | Protection of Information at Rest | AES-256 encryption at rest (default); Tri-Secret Secure for highest sensitivity |
| SI-4 | System Monitoring | Alerts for ACCOUNTADMIN usage, break-glass login, DDL changes |
