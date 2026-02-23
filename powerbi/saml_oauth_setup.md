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

Run the following SQL as `ACCOUNTADMIN`:

```sql
-- OAuth Security Integration (for Power BI Service / Gateway)
CREATE SECURITY INTEGRATION IF NOT EXISTS POWERBI_OAUTH
    TYPE                      = OAUTH
    ENABLED                   = TRUE
    OAUTH_CLIENT              = CUSTOM
    OAUTH_CLIENT_TYPE         = 'CONFIDENTIAL'
    OAUTH_REDIRECT_URI        = 'https://login.microsoftonline.com/common/oauth2/nativeclient'
    OAUTH_ISSUE_REFRESH_TOKENS = TRUE
    OAUTH_REFRESH_TOKEN_VALIDITY = 86400  -- 24 hours
    COMMENT = 'OAuth integration for Power BI user impersonation via Azure AD.';
```

After creation, retrieve the OAuth endpoint details:

```sql
DESC SECURITY INTEGRATION POWERBI_OAUTH;
-- Note: OAUTH_AUTHORIZATION_ENDPOINT, OAUTH_TOKEN_ENDPOINT
```

---

## Step 3: Configure SAML SSO for Human Users

For human users (analysts opening Snowsight or connecting via Power BI Desktop):

```sql
-- SAML2 Security Integration (for Snowsight and SnowSQL SSO)
CREATE SECURITY INTEGRATION IF NOT EXISTS AZURE_AD_SAML
    TYPE                       = SAML2
    ENABLED                    = TRUE
    SAML2_ISSUER               = 'https://sts.windows.net/<AZURE_AD_TENANT_ID>/'
    SAML2_SSO_URL              = 'https://login.microsoftonline.com/<AZURE_AD_TENANT_ID>/saml2'
    SAML2_PROVIDER             = 'ADFS'
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

Snowflake can automatically assign roles based on the `roles` claim in the SAML assertion.
Configure Azure AD to include group memberships in the SAML token:

**Azure Portal → Enterprise Applications → your app → Single sign-on → User Attributes & Claims → Add group claim:**
- Select: `Security Groups` or `All Groups`
- Source attribute: `Group ID` (or `sAMAccountName` for on-prem sync)

Then create Snowflake role mappings:

```sql
-- Map Azure AD group ObjectID → Snowflake role
-- Run as SECURITYADMIN

-- Users in AD group PBI_MARKETING (ObjectID: xxxxxxxx-...) → POWERBI_MARKETING_ROLE
ALTER ACCOUNT SET SAML2_SNOWFLAKE_ROLE_ATTRIBUTE = 'https://schemas.microsoft.com/ws/2008/06/identity/claims/role';

-- In the SAML token, Azure AD must send the Snowflake role name as a claim value.
-- Configure Azure AD group → role mapping in the token claims:
--   Claim name: https://schemas.microsoft.com/ws/2008/06/identity/claims/role
--   Value: POWERBI_MARKETING_ROLE  (for users in PBI_MARKETING group)
--   Value: POWERBI_FINANCE_ROLE    (for users in PBI_FINANCE group)
```

> **Alternative approach**: Use Snowflake's `ROLE` parameter in the connection string.
> Power BI sends `role=POWERBI_MARKETING_ROLE` and Snowflake validates it against
> the user's granted roles. This is simpler but requires per-report configuration.

---

## Step 5: Power BI Gateway Configuration

### For Power BI Service (cloud) connecting via On-Premises Data Gateway:

1. Install **On-Premises Data Gateway** on a server with network access to Snowflake.
2. In Power BI Service → Settings → Manage gateways → Add data source:
   - **Data Source Type**: Snowflake
   - **Server**: `<account>.snowflakecomputing.com`
   - **Database**: `ANALYTICS_DB`
   - **Authentication Method**: `OAuth2`
   - **Username**: `SVC_POWERBI` (service account)
   - Under Advanced → **Additional Connection Properties**: `warehouse=ANALYTICS_WH;role=POWERBI_ROLE`

### For Power BI Desktop (developer workstation):

1. Get Data → Snowflake
2. Server: `<account>.snowflakecomputing.com`
3. Database: `ANALYTICS_DB`
4. Authentication: **Microsoft Account** (triggers Azure AD OAuth flow)
5. The user's AD group membership determines their Snowflake role assignment.

---

## Step 6: Configure Power BI Report-Level RLS (Complementary)

Power BI has its own row-level security that works **in addition to** Snowflake's.
Configure Power BI RLS as a defence-in-depth measure:

In Power BI Desktop:
1. Modelling tab → Manage Roles → New Role
2. For `Marketing Analyst` role: add DAX filter on `data_domain` column: `[data_domain] = "MARKETING"`
3. In Power BI Service: assign AD group `PBI_MARKETING` to the `Marketing Analyst` role.

> **Note**: Snowflake Row Access Policy is the authoritative enforcement layer.
> Power BI RLS is a UX convenience — users won't see data outside their domain
> even if they try to modify report filters.

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
| "JWT token expired" | OAuth refresh token expired (>24h) | Re-authenticate in Power BI; increase `OAUTH_REFRESH_TOKEN_VALIDITY` |
| Email shows as `***@***.***` | Masking policy active — expected! | Add user to `DATA_ANALYST_ROLE` if partial unmask is required |
| SAML assertion error | Cert mismatch | Re-download metadata XML from Azure AD; update `SAML2_X509_CERT` |

---

## Security Checklist

- [ ] Network policy restricts PBI gateway IP (see `05_network_policies.sql`)
- [ ] Service account (`SVC_POWERBI`) uses key-pair auth — no password
- [ ] MFA enforced for all human users via Azure AD Conditional Access
- [ ] OAUTH_REFRESH_TOKEN_VALIDITY set to ≤24h
- [ ] Row Access Policies applied to all gold layer tables
- [ ] Column masking applied to all PII columns
- [ ] Power BI RLS configured as defence-in-depth
- [ ] Regular access review scheduled (quarterly)
