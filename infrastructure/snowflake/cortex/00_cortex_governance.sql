-- =============================================================================
-- cortex/00_cortex_governance.sql
-- Governance for Snowflake Cortex AI — run this BEFORE enabling any Cortex
-- workload (semantic views / Analyst, Search, AISQL functions, agents).
--
-- WHY GOVERNANCE FIRST
-- --------------------
--   1. ACCESS: Snowflake grants the SNOWFLAKE.CORTEX_USER database role to
--      PUBLIC by default — every user in the account can call LLM functions
--      (and spend credits) unless you revoke it and grant deliberately.
--   2. DATA EXPOSURE: LLM functions read whatever the CALLING ROLE can read.
--      A role that sees unmasked PII can send unmasked PII to an LLM function.
--      Pair Cortex grants with the masking model: analyst/scientist roles see
--      masked PII (03_column_masking_policies.sql), so their Cortex calls do
--      too. Be deliberate before granting Cortex to TRANSFORMER_ROLE flows
--      that read unmasked silver data.
--   3. MODELS & REGIONS: pin which models may be used, and whether requests
--      may leave your region (cross-region inference is DISABLED by default —
--      keep it that way in regulated environments).
--   4. COST: AI services bill per token as serverless credits. Monitor them
--      like any other workload.
--
-- GOVERNMENT / PUBLIC SECTOR NOTES
-- ---------------------------------
-- • Cortex AI is available in SnowGov FedRAMP High / DoD IL5 environments,
--   with a narrower model list than commercial regions — verify current model
--   availability for your region before pinning the allowlist.
-- • Keep CORTEX_ENABLED_CROSS_REGION = 'DISABLED' in any environment with a
--   data residency or authorization boundary; cross-region inference sends
--   prompts to another region's inference infrastructure.
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- 1. ACCESS: revoke the default PUBLIC grant; grant per role
-- ---------------------------------------------------------------------------

REVOKE DATABASE ROLE SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC;

-- Analysts and scientists: LLM functions over data they can already read
-- (their reads are masked per 03_column_masking_policies.sql)
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DATA_ANALYST_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DATA_SCIENTIST_ROLE;

-- dbt: required only if AI-enrichment models are enabled
-- (dbt/models/gold/ai/ — var 'enable_ai_enrichment'). The transformer reads
-- UNMASKED silver data; only enable once you have reviewed which columns its
-- AI models send to LLM functions.
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE TRANSFORMER_ROLE;

-- ---------------------------------------------------------------------------
-- 2. MODEL ALLOWLIST
-- Pin the models your governance process has approved. 'All' (default) means
-- every model Snowflake offers in-region; 'None' disables Cortex functions.
-- ---------------------------------------------------------------------------

-- Example: allow only the models your review approved (adjust to taste):
-- ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = 'claude-sonnet-4-5,mistral-large2,snowflake-arctic-embed-l-v2.0';

-- ---------------------------------------------------------------------------
-- 3. CROSS-REGION INFERENCE
-- DISABLED by default. Enabling routes requests to other regions when a model
-- is not available locally — a data-residency decision, not a convenience one.
-- ---------------------------------------------------------------------------

-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'DISABLED';        -- explicit default
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';      -- only with governance sign-off

-- ---------------------------------------------------------------------------
-- 4. COST VISIBILITY
-- AI services appear in METERING_DAILY_HISTORY as SERVICE_TYPE = 'AI_SERVICES'
-- (cost_report.sql query 6 already includes them). Function-level detail:
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.COST_MANAGEMENT.VW_AI_SERVICES_DAILY AS
SELECT
    usage_date,
    credits_used,
    ROUND(credits_used * 3.00, 2) AS estimated_cost_usd   -- adjust $/credit
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE service_type = 'AI_SERVICES'
ORDER BY usage_date DESC;

GRANT SELECT ON VIEW MONITORING_DB.COST_MANAGEMENT.VW_AI_SERVICES_DAILY
    TO ROLE DATA_ENGINEER_ROLE;

-- Per-function / per-model token detail (query ad hoc):
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
-- ORDER BY start_time DESC;

-- Guardrail: alert if AI services exceed a daily credit budget
CREATE ALERT IF NOT EXISTS ALERT_AI_SERVICES_SPEND
    SCHEDULE = '60 MINUTES'
    IF (EXISTS (
        SELECT 1
        FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
        WHERE service_type = 'AI_SERVICES'
          AND usage_date >= DATEADD('day', -1, CURRENT_DATE())
        HAVING SUM(credits_used) > 10          -- daily AI credit budget — adjust
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_NOTIFICATION',
            'data-platform-alerts@mycompany.com',
            'ALERT: Cortex AI credit spend above daily budget',
            'AI services (Cortex functions / Search / Analyst) consumed more than '
            || 'the configured daily credit budget in the last day. Review '
            || 'MONITORING_DB.COST_MANAGEMENT.VW_AI_SERVICES_DAILY and '
            || 'SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY.'
        );

ALTER ALERT ALERT_AI_SERVICES_SPEND RESUME;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- SHOW GRANTS OF DATABASE ROLE SNOWFLAKE.CORTEX_USER;
-- SHOW PARAMETERS LIKE 'CORTEX%' IN ACCOUNT;
