-- =============================================================================
-- cortex/04_document_ai_ingestion.sql
-- Extends the medallion architecture to UNSTRUCTURED documents: PDFs (invoices,
-- contracts, delivery notes) landing in S3 flow into bronze as parsed text +
-- layout, ready for silver-layer structuring with AISQL extraction.
--
-- PATTERN
-- -------
--   S3 prefix (raw/documents/)                 ── files arrive
--     → directory stage + stream               ── change tracking
--     → task: AI_PARSE_DOCUMENT per new file   ── bronze: full parsed content
--     → silver: AI_EXTRACT / AI_COMPLETE       ── typed business fields
--
-- This mirrors the structured pattern (stage → landing table → dbt), so the
-- same governance applies: bronze is immutable raw, extraction logic is
-- versioned transformation code.
--
-- COST: AI_PARSE_DOCUMENT bills per page as AI_SERVICES credits. Gate the
-- task's schedule and monitor via VW_AI_SERVICES_DAILY (00_cortex_governance).
--
-- Run as: ACCOUNTADMIN (integration usage) / SYSADMIN
-- Prerequisites: 01_storage_integration_s3.sql (add the documents prefix to
--                STORAGE_ALLOWED_LOCATIONS), 00_cortex_governance.sql.
-- =============================================================================

USE ROLE SYSADMIN;
USE DATABASE RAW_DB;
USE SCHEMA S3_RAW;

-- ---------------------------------------------------------------------------
-- 1. DIRECTORY STAGE for documents
-- ---------------------------------------------------------------------------

CREATE STAGE IF NOT EXISTS RAW_DB.S3_RAW.STG_S3_DOCUMENTS
    STORAGE_INTEGRATION = S3_RAW_INTEGRATION
    URL                 = 's3://<YOUR_BUCKET_NAME>/raw/documents/'
    DIRECTORY           = (ENABLE = TRUE)
    COMMENT             = 'Unstructured documents (PDF/DOCX) for AI parsing into bronze.';

-- Refresh the directory listing after files land (or configure event-based
-- auto-refresh with the bucket's SNS/SQS notifications):
-- ALTER STAGE RAW_DB.S3_RAW.STG_S3_DOCUMENTS REFRESH;

-- Stream over the stage's directory table = "which files are new since last consume"
CREATE STREAM IF NOT EXISTS RAW_DB.S3_RAW.STRM_S3_DOCUMENTS
    ON STAGE RAW_DB.S3_RAW.STG_S3_DOCUMENTS
    COMMENT = 'New-document change feed for the parsing task.';

-- ---------------------------------------------------------------------------
-- 2. BRONZE LANDING TABLE for parsed documents
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS RAW_DB.S3_RAW.DOCUMENTS_LANDING (
    relative_path   VARCHAR(1000),
    file_size       NUMBER,
    last_modified   TIMESTAMP_TZ,
    parsed          VARIANT,        -- AI_PARSE_DOCUMENT output: content + layout
    _loaded_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Bronze: raw parsed content of unstructured documents. Immutable.';

GRANT SELECT ON TABLE RAW_DB.S3_RAW.DOCUMENTS_LANDING TO ROLE TRANSFORMER_ROLE;

-- ---------------------------------------------------------------------------
-- 3. PARSING TASK — consumes the stream, parses each new file
-- ---------------------------------------------------------------------------

CREATE TASK IF NOT EXISTS RAW_DB.S3_RAW.TASK_PARSE_DOCUMENTS
    WAREHOUSE = INGESTION_WH
    SCHEDULE  = '60 MINUTES'
    WHEN SYSTEM$STREAM_HAS_DATA('RAW_DB.S3_RAW.STRM_S3_DOCUMENTS')
    COMMENT   = 'Parses newly-arrived documents into DOCUMENTS_LANDING via AI_PARSE_DOCUMENT.'
AS
    INSERT INTO RAW_DB.S3_RAW.DOCUMENTS_LANDING
        (relative_path, file_size, last_modified, parsed)
    SELECT
        relative_path,
        size,
        last_modified,
        AI_PARSE_DOCUMENT(
            TO_FILE('@RAW_DB.S3_RAW.STG_S3_DOCUMENTS', relative_path),
            {'mode': 'LAYOUT'}          -- LAYOUT preserves tables/structure; OCR for scans
        )
    FROM RAW_DB.S3_RAW.STRM_S3_DOCUMENTS
    WHERE relative_path ILIKE ANY ('%.pdf', '%.docx');

-- ALTER TASK RAW_DB.S3_RAW.TASK_PARSE_DOCUMENTS RESUME;

-- ---------------------------------------------------------------------------
-- 4. SILVER: structure the parsed text with AISQL (dbt model or task)
-- Example extraction — pull typed fields out of parsed invoices:
-- ---------------------------------------------------------------------------

-- SELECT
--     relative_path,
--     AI_EXTRACT(
--         text            => parsed:content::VARCHAR,
--         responseFormat  => [
--             ['invoice_number', 'What is the invoice number?'],
--             ['invoice_date',   'What is the invoice date (ISO format)?'],
--             ['total_amount',   'What is the total amount due, numbers only?'],
--             ['currency',       'What currency is the invoice in (ISO 4217)?']
--         ]
--     ) AS extracted
-- FROM RAW_DB.S3_RAW.DOCUMENTS_LANDING
-- WHERE _loaded_at >= DATEADD('day', -1, CURRENT_TIMESTAMP());
--
-- Productionise as a dbt silver model (slv_documents_invoices) with tests on
-- the extracted fields, exactly like any other silver entity. See
-- https://docs.snowflake.com/en/sql-reference/functions/ai_parse_document and
-- https://docs.snowflake.com/en/sql-reference/functions/ai_extract for current
-- signatures.
