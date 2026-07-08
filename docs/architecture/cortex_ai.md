# Cortex AI Layer

This document describes how Snowflake Cortex AI services are incorporated into
the accelerator — governance first, then capability. All scripts live in
`infrastructure/snowflake/cortex/`.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  GOVERNANCE (00_cortex_governance.sql — run FIRST)                       │
│  CORTEX_USER role hygiene · model allowlist · cross-region posture ·     │
│  AI_SERVICES cost monitoring + budget alert                              │
└──────────────┬───────────────────────────────────────────────────────────┘
               │
   ┌───────────┼──────────────────┬─────────────────────┬─────────────────┐
   ▼           ▼                  ▼                     ▼                 ▼
Semantic    Cortex Search      ML anomaly           Document AI       AISQL in dbt
views +     over runbooks      detection on         ingestion         (opt-in gold/ai
Analyst     (02)               credit spend (03)    (04)              models)
(01)
```

---

## What each piece does

| Script | Capability | Consumes | Notes |
|--------|-----------|----------|-------|
| `00_cortex_governance.sql` | Access, model allowlist, cross-region posture, cost alert | — | **Prerequisite for everything else.** CORTEX_USER is granted to PUBLIC by default — this revokes it and grants deliberately. |
| `01_semantic_views.sql` | Governed semantic models (`SV_REVENUE`, `SV_CUSTOMER_360`) for **Cortex Analyst** and **Snowflake Intelligence** | Gold tables | RLS on the underlying tables applies to the querying user. PII columns are deliberately not modelled as dimensions. |
| `02_cortex_search.sql` | Hybrid retrieval over the repo's runbooks/docs | `MONITORING_DB.KNOWLEDGE.PLATFORM_DOCS` | On-call Q&A with citations; also the retrieval tool for agents. |
| `03_anomaly_monitoring.sql` | `SNOWFLAKE.ML.ANOMALY_DETECTION` on daily credit spend | `VW_DAILY_CREDIT_USAGE` | Learned baseline replaces static thresholds; same pattern extends to dbt test-failure rates. |
| `04_document_ai_ingestion.sql` | Unstructured-document bronze: `AI_PARSE_DOCUMENT` from a directory stage; `AI_EXTRACT` in silver | S3 `raw/documents/` | Extends the medallion to PDFs/DOCX with the same stage→landing→dbt discipline. |
| `dbt/models/gold/ai/` | AISQL enrichment inside dbt (`AI_CLASSIFY` for missing product categories) | Silver | **Opt-in** (`enable_ai_enrichment` var), incremental so each row is classified once, per-run batch cap. |

---

## Agents and Snowflake Intelligence

Cortex Agents (GA) orchestrate tools — Cortex Analyst for structured questions,
Cortex Search for documents — under Snowflake RBAC. This template deliberately
ships the agent *building blocks* as code and leaves agent assembly to
Snowsight, where they are configured and versioned:

1. **Snowsight → AI & ML → Agents** (or Snowflake Intelligence) → create an
   agent per domain audience.
2. Attach tools:
   - Analyst tool → `ANALYTICS_DB.FINANCE.SV_REVENUE` (finance agent) or
     `ANALYTICS_DB.MARKETING.SV_CUSTOMER_360` (marketing agent)
   - Search tool → `MONITORING_DB.KNOWLEDGE.RUNBOOK_SEARCH` (platform agent)
3. Restrict each agent to the matching role (`POWERBI_FINANCE_ROLE` users get
   the finance agent, etc.). Agents execute with the user's rights — the row
   access policies keep answers domain-scoped.
4. Optional integrations: Microsoft Teams / Copilot connectivity and MCP
   endpoints let the same governed agents serve users outside Snowsight.

---

## Guardrails checklist (before enabling any Cortex workload)

- [ ] `00_cortex_governance.sql` applied: PUBLIC revoked, roles granted deliberately
- [ ] Model allowlist pinned to approved models
- [ ] `CORTEX_ENABLED_CROSS_REGION` left `DISABLED` unless governance signed off
- [ ] `ALERT_AI_SERVICES_SPEND` budget threshold set to your comfort level
- [ ] Roles granted `CORTEX_USER` see PII **masked** (their reads pass through
      `03_column_masking_policies.sql`) — do not grant Cortex to raw-reading
      roles without a data-exposure review
- [ ] Government/regulated: verify model availability in your SnowGov region and
      keep cross-region inference disabled

---

## Cost model

Cortex bills serverless credits per token/page/query under
`SERVICE_TYPE = 'AI_SERVICES'` (Trust Center scanners bill as `TRUST_CENTER`).
Monitoring surfaces:

- `MONITORING_DB.COST_MANAGEMENT.VW_AI_SERVICES_DAILY` — daily AI credits
- `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY` — per-function/model tokens
- `scripts/utilities/cost_report.sql` query 6 — AI services alongside all other serverless spend
- `ALERT_AI_SERVICES_SPEND` — daily budget breach alert
