# Power BI → Snowflake: SAML/OAuth Integration Guide

This guide covers the end-to-end setup for connecting Microsoft Power BI to Snowflake
using Azure AD SSO (SAML 2.0 / OAuth 2.0), so that Power BI users authenticate with
their corporate credentials and Snowflake enforces row-level security based on their
AD group memberships.

---

## Architecture Overview

```
┌──────────────┐        SAML 2.0 / OAuth 2.0        ┌───────────────────┐
│   Power BI   │ ────────────────────────────────►  │   Azure AD (IdP)  │
│   Service    │                                     │                   │
│   / Desktop  │ ◄──────────── JWT token ──────────  │  App Registration │
└──────┬───────┘                                     └───────────────────┘
       │                                                        │
       │  JWT token passed as OAuth bearer                      │ AD group claims
       ▼                                                        ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         Snowflake                                    │
│  Security Integration (OAUTH) validates JWT → maps to Snowflake role │
│  Row Access Policy evaluates CURRENT_ROLE() at query time            │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Item | Details |
|------|---------|
| Azure AD tenant | Tenant ID from Azure Portal → Azure Active Directory |
| Power BI Premium / Pro | Required for gateway and DirectQuery |
| Snowflake Enterprise | Required for SAML SSO integration |
| AD Groups | `PBI_MARKETING`, `PBI_FINANCE`, `PBI_OPERATIONS` created in Azure AD |

---

## Step 1: Register an Application in Azure AD

1. Navigate to **Azure Portal → Azure Active Directory → App registrations → New registration**.
2. Set **Name**: `Snowflake Power BI Integration`
3. Set **Supported account types**: `Accounts in this organizational directory only`
4. Set **Redirect URI**: leave blank for now.
5. Click **Register** and note the **Application (client) ID** and **Directory (tenant) ID**.
6. Under **Certificates & secrets**, create a new **Client secret**. Store it in Azure Key Vault.
7. Under **API permissions**, add `Snowflake → user_impersonation` (if using OAuth flow).

---

## Step 2: Configure Snowflake Security Integration

Power BI authenticates users against **Microsoft Entra ID (Azure AD)** and passes
the Entra-issued token to Snowflake. Snowflake must therefore be configured to
*trust an external issuer* — that is an **External OAuth** integration
(`TYPE = EXTERNAL_OAUTH`), **not** a Snowflake-native OAuth server
(`TYPE = OAUTH, OAUTH_CLIENT = CUSTOM`, which would make Snowflake the issuer
and does not fit the Power BI flow).

Run the following SQL as `ACCOUNTADMIN`:

```sql
-- External OAuth integration trusting Entra ID tokens (Power BI SSO)
CREATE SECURITY INTEGRATION IF NOT EXISTS POWERBI_EXTERNAL_OAUTH
    TYPE                                            = EXTERNAL_OAUTH
    ENABLED                                         = TRUE
    EXTERNAL_OAUTH_TYPE                             = AZURE
    EXTERNAL_OAUTH_ISSUER                           = 'https://sts.windows.net/<AZURE_AD_TENANT_ID>/'
    EXTERNAL_OAUTH_JWS_KEYS_URL                     = 'https://login.microsoftonline.com/<AZURE_AD_TENANT_ID>/discovery/v2.0/keys'
    EXTERNAL_OAUTH_AUDIENCE_LIST                    = ('https://analysis.windows.net/powerbi/connector/Snowflake')
    EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM         = 'upn'
    EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'LOGIN_NAME'
    COMMENT = 'Trusts Entra ID tokens issued for the Power BI Snowflake connector (SSO).';
```

Notes:

- The audience value above is the fixed Power BI Snowflake connector audience.
- Each Power BI user must exist in Snowflake with a `LOGIN_NAME` matching their
  UPN — SCIM provisioning (`07_scim_integration.sql`) handles this.
- In the Power BI Service tenant settings, an admin must enable
  **Snowflake SSO** (Settings → Admin portal → Integration settings).

---

## Step 3: Configure SAML SSO for Human Users

For human users (analysts opening Snowsight or connecting via Power BI Desktop):

```sql
-- SAML2 Security Integration (for Snowsight and CLI SSO)
CREATE SECURITY INTEGRATION IF NOT EXISTS AZURE_AD_SAML
    TYPE                       = SAML2
    ENABLED                    = TRUE
    SAML2_ISSUER               = 'https://sts.windows.net/<AZURE_AD_TENANT_ID>/'
    SAML2_SSO_URL              = 'https://login.microsoftonline.com/<AZURE_AD_TENANT_ID>/saml2'
    SAML2_PROVIDER             = 'CUSTOM'   -- Entra ID uses CUSTOM ('ADFS' is on-prem AD FS only)
    SAML2_X509_CERT            = '<BASE64_ENCODED_CERT_FROM_AZURE_AD>'
    SAML2_SP_INITIATED_LOGIN_PAGE_LABEL = 'Login with Microsoft'
    SAML2_ENABLE_SP_INITIATED  = TRUE
    SAML2_SNOWFLAKE_ACS_URL    = 'https://<SNOWFLAKE_ACCOUNT>.snowflakecomputing.com/fed/login'
    SAML2_SNOWFLAKE_ISSUER_URL = 'https://<SNOWFLAKE_ACCOUNT>.snowflakecomputing.com'
    COMMENT = 'Azure AD SAML2 integration for SSO.';
```

**To get the SAML2_X509_CERT:**
1. Azure Portal → App Registrations → your app → Certificates & secrets → Download federation metadata XML
2. Extract the `<X509Certificate>` value from the XML

---

## Step 4: Map Azure AD Groups to Snowflake Roles

Snowflake does **not** assign roles from SAML/OAuth token claims — role
membership is managed inside Snowflake. The automated path is **SCIM group
provisioning** (`account_setup/07_scim_integration.sql`):

1. In the Entra ID Snowflake provisioning app, enable **group provisioning**.
2. Assign the AD groups to the app; SCIM creates a same-named role membership
   in Snowflake and keeps it in sync as people join/leave the group:

   | AD Group          | Snowflake Role            |
   |-------------------|---------------------------|
   | `PBI_MARKETING`   | `POWERBI_MARKETING_ROLE`  |
   | `PBI_FINANCE`     | `POWERBI_FINANCE_ROLE`    |
   | `PBI_OPERATIONS`  | `POWERBI_OPERATIONS_ROLE` |

3. Ensure each provisioned role is granted into the hierarchy
   (`account_setup/03_roles.sql` already grants the domain roles to
   `POWERBI_ROLE`).

> **Connection-level role**: Power BI can also pass `role=POWERBI_MARKETING_ROLE`
> as a connection property. Snowflake validates it against the user's granted
> roles — it selects which granted role the session uses, it does not grant
> anything.

---

## Step 5: Choose the Connectivity Model — WHERE RLS IS ACTUALLY ENFORCED

The two Power BI connectivity models enforce row security in **different
places**. Be explicit about which one each dataset uses:

### Model A — DirectQuery + AAD SSO (Snowflake enforces RLS per user)

Every report interaction runs as the **viewing user's own Snowflake identity**,
so the Snowflake Row Access Policies and masking policies apply per user.

1. Dataset connection mode: **DirectQuery**.
2. In the dataset settings (or gateway data source), enable
   **"Use SSO via Azure AD for DirectQuery queries"**.
3. Users must exist in Snowflake (SCIM) and hold a domain role (Step 4).
4. The External OAuth integration from Step 2 validates the per-user tokens.

Use Model A whenever Snowflake-enforced, per-user RLS is a requirement.

### Model B — Import mode via the SVC_POWERBI service account

The dataset is **refreshed by `SVC_POWERBI` under `POWERBI_ROLE`**, which the
`DOMAIN_ACCESS_POLICY` intentionally allows to read **all rows**. The imported
dataset therefore contains everything; the ONLY row filtering end users get is
**Power BI dataset RLS** (DAX roles). Snowflake RLS does not see those users.

1. Install the **On-Premises Data Gateway** (or use a VNet gateway).
2. Power BI Service → Manage gateways → Add data source:
   - **Server**: `<account>.snowflakecomputing.com`
   - **Database**: `ANALYTICS_DB`
   - **Authentication**: Key-pair via the connector's supported mechanism for
     `SVC_POWERBI` (no password — see `04_users.sql`)
   - Advanced → connection properties: `warehouse=ANALYTICS_WH;role=POWERBI_ROLE`
3. Configure Power BI dataset RLS (below) — in this model it is the
   **authoritative** control, not defence-in-depth. Masking still applies at
   refresh time: PII columns imported through `POWERBI_ROLE` arrive masked.

### For Power BI Desktop (developer workstation):

1. Get Data → Snowflake
2. Server: `<account>.snowflakecomputing.com`; Database: `ANALYTICS_DB`
3. Authentication: **Microsoft Account** (Azure AD OAuth → the user's own
   Snowflake identity; Snowflake RLS/masking apply per user)

---

## Step 6: Configure Power BI Report-Level RLS

In Power BI Desktop:
1. Modelling tab → Manage Roles → New Role
2. For `Marketing Analyst` role: add DAX filter on `data_domain` column: `[data_domain] = "MARKETING"`
3. In Power BI Service: assign AD group `PBI_MARKETING` to the `Marketing Analyst` role.

> **Enforcement summary**:
> • Model A (DirectQuery + SSO): Snowflake Row Access Policies are
>   authoritative; Power BI RLS is defence-in-depth.
> • Model B (import via service account): Power BI dataset RLS is the ONLY
>   row-level control users experience — treat its configuration with the
>   same rigour as a Snowflake policy change, and prefer Model A for
>   sensitive domains.

---

## Step 7: Test and Verify

```sql
-- Verify role mapping for a test user (run as ACCOUNTADMIN)
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE user_name = 'testuser@mycompany.com'
ORDER BY event_timestamp DESC LIMIT 10;

-- Verify row access policy is working (connect as POWERBI_MARKETING_ROLE)
-- This should return only rows where data_domain = 'MARKETING'
SELECT DISTINCT data_domain FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360;

-- Verify masking is working (email should be masked for PBI role)
SELECT email_address FROM ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360 LIMIT 1;
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "Insufficient privileges" on Power BI refresh | User not in correct AD group | Add user to `PBI_MARKETING` (or appropriate) AD group |
| Empty dashboard after SSO login | Row access policy filtering all rows | Check CURRENT_ROLE() matches policy; verify role grant |
| "JWT token expired" | Entra-issued access token expired mid-session | Re-authenticate in Power BI; token lifetime is governed by Entra ID Conditional Access / token policies, not by Snowflake |
| Email shows as `***@***.***` | Masking policy active — expected! | Add user to `DATA_ANALYST_ROLE` if partial unmask is required |
| SAML assertion error | Cert mismatch | Re-download metadata XML from Azure AD; update `SAML2_X509_CERT` |

---

## Security Checklist

- [ ] Network policy restricts PBI gateway IP (see `05_network_policies.sql`)
- [ ] Service account (`SVC_POWERBI`) uses key-pair auth — no password
- [ ] MFA enforced for all human users via Azure AD Conditional Access
- [ ] Entra ID token lifetime / Conditional Access session policies reviewed for the Snowflake connector
- [ ] Row Access Policies applied to all gold layer tables
- [ ] Column masking applied to all PII columns
- [ ] Power BI RLS configured as defence-in-depth
- [ ] Regular access review scheduled (quarterly)
