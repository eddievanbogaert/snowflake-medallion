-- =============================================================================
-- cortex/02_cortex_search.sql
-- Cortex Search over the platform's own runbooks and operational docs, so
-- on-call engineers (and Snowflake Intelligence agents) can ask questions like
-- "how do I fail over to the DR account?" and get grounded answers with
-- citations — instead of grepping the repo at 3am.
--
-- HOW IT WORKS
-- ------------
-- Cortex Search is a managed hybrid (vector + keyword) retrieval service over
-- a query you define. It refreshes itself on TARGET_LAG, bills serverless
-- credits (SERVICE_TYPE = 'AI_SERVICES'), and is queried from SQL, REST, or as
-- the retrieval tool of a Cortex Agent.
--
-- Run as: ACCOUNTADMIN
-- Prerequisites: 00_cortex_governance.sql
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- 1. SOURCE TABLE for platform documentation
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS MONITORING_DB.KNOWLEDGE
    COMMENT = 'Platform documentation corpus for Cortex Search.';

CREATE TABLE IF NOT EXISTS MONITORING_DB.KNOWLEDGE.PLATFORM_DOCS (
    doc_path     VARCHAR(500)  NOT NULL,   -- e.g. docs/runbooks/incident-response.md
    title        VARCHAR(500),
    category     VARCHAR(100),             -- runbook | architecture | powerbi | sql-reference
    content      VARCHAR,                  -- full markdown/text content
    updated_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- 2. LOAD the docs
-- Simplest repeatable path: a tiny loader script that PUTs the repo's
-- markdown into a stage and copies it in. From the repo root:
--
--   snow sql -q "CREATE STAGE IF NOT EXISTS MONITORING_DB.KNOWLEDGE.DOC_STAGE"
--   snow stage copy docs/ @MONITORING_DB.KNOWLEDGE.DOC_STAGE/docs/ --recursive
--
-- Then parse each staged file into a row (PARSE_DOCUMENT handles text
-- extraction; markdown is ingested as text):
--
-- INSERT INTO MONITORING_DB.KNOWLEDGE.PLATFORM_DOCS (doc_path, title, category, content)
-- SELECT
--     relative_path,
--     SPLIT_PART(relative_path, '/', -1),
--     SPLIT_PART(relative_path, '/', 2),          -- runbooks / architecture
--     TO_VARCHAR(SNOWFLAKE.CORTEX.PARSE_DOCUMENT(@MONITORING_DB.KNOWLEDGE.DOC_STAGE,
--                                                relative_path):content)
-- FROM DIRECTORY(@MONITORING_DB.KNOWLEDGE.DOC_STAGE)
-- WHERE relative_path ILIKE '%.md';
--
-- Re-run after doc changes (or wrap in a task keyed on the directory stream).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. SEARCH SERVICE
-- ---------------------------------------------------------------------------

CREATE OR REPLACE CORTEX SEARCH SERVICE MONITORING_DB.KNOWLEDGE.RUNBOOK_SEARCH
    ON content
    ATTRIBUTES doc_path, title, category
    WAREHOUSE = ADMIN_WH                 -- used for the refresh query only
    TARGET_LAG = '1 day'
    AS (
        SELECT
            content,
            doc_path,
            title,
            category
        FROM MONITORING_DB.KNOWLEDGE.PLATFORM_DOCS
    );

-- ---------------------------------------------------------------------------
-- 4. ACCESS
-- ---------------------------------------------------------------------------

GRANT USAGE ON SCHEMA MONITORING_DB.KNOWLEDGE TO ROLE DATA_ENGINEER_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE MONITORING_DB.KNOWLEDGE.RUNBOOK_SEARCH
    TO ROLE DATA_ENGINEER_ROLE;

-- ---------------------------------------------------------------------------
-- 5. QUERY IT
-- ---------------------------------------------------------------------------
-- SELECT PARSE_JSON(
--     SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
--         'MONITORING_DB.KNOWLEDGE.RUNBOOK_SEARCH',
--         '{
--            "query": "how do I fail over to the DR account",
--            "columns": ["doc_path", "title", "content"],
--            "limit": 3
--          }'
--     )
-- )['results'] AS results;
--
-- The same service plugs into a Cortex Agent / Snowflake Intelligence as its
-- retrieval tool — see docs/architecture/cortex_ai.md.
