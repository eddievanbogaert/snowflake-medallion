-- =============================================================================
-- 02_external_stages.sql
-- Creates external stages pointing to S3 and configures Snowpipe for auto-ingest.
--
-- Patterns covered:
--   1. Named S3 stage per data domain (customers, events, transactions)
--   2. File format definitions for CSV and Parquet
--   3. Snowpipe definitions for continuous micro-batch loading
--   4. Target landing tables in RAW_DB
--
-- Prerequisites: Run 01_storage_integration_s3.sql first.
-- Run as: LOADER_ROLE (or SYSADMIN)
-- =============================================================================

USE ROLE SYSADMIN;
USE DATABASE RAW_DB;

-- ---------------------------------------------------------------------------
-- FILE FORMAT DEFINITIONS
-- ---------------------------------------------------------------------------

CREATE FILE FORMAT IF NOT EXISTS RAW_DB.S3_RAW.FF_CSV_STANDARD
    TYPE                  = CSV
    SKIP_HEADER           = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF               = ('NULL', 'null', '', 'N/A', 'NA')
    EMPTY_FIELD_AS_NULL   = TRUE
    DATE_FORMAT           = 'AUTO'
    TIMESTAMP_FORMAT      = 'AUTO'
    ENCODING              = 'UTF8'
    COMMENT               = 'Standard CSV: quoted fields, header row, auto date detection.';

CREATE FILE FORMAT IF NOT EXISTS RAW_DB.S3_RAW.FF_CSV_PIPE_DELIMITED
    TYPE                  = CSV
    FIELD_DELIMITER       = '|'
    SKIP_HEADER           = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF               = ('NULL', 'null', '')
    EMPTY_FIELD_AS_NULL   = TRUE
    COMMENT               = 'Pipe-delimited CSV — common SQL Server BCP export format.';

CREATE FILE FORMAT IF NOT EXISTS RAW_DB.S3_RAW.FF_PARQUET
    TYPE                  = PARQUET
    SNAPPY_COMPRESSION    = TRUE
    COMMENT               = 'Parquet with Snappy compression — preferred for large datasets.';

CREATE FILE FORMAT IF NOT EXISTS RAW_DB.S3_RAW.FF_JSON
    TYPE                  = JSON
    STRIP_OUTER_ARRAY     = TRUE
    DATE_FORMAT           = 'AUTO'
    TIMESTAMP_FORMAT      = 'AUTO'
    COMMENT               = 'JSON file format for event/log ingestion.';

-- ---------------------------------------------------------------------------
-- EXTERNAL STAGES
-- Each domain has its own prefix in S3 for clear data segregation.
-- ---------------------------------------------------------------------------

-- Customer data exports from SQL Server / ADF
CREATE STAGE IF NOT EXISTS RAW_DB.S3_RAW.STG_S3_CUSTOMERS
    STORAGE_INTEGRATION = S3_RAW_INTEGRATION
    URL                 = 's3://<YOUR_BUCKET_NAME>/raw/customers/'
    FILE_FORMAT         = RAW_DB.S3_RAW.FF_CSV_PIPE_DELIMITED
    COMMENT             = 'Pipe-delimited customer extracts from SQL Server via ADF.';

-- Event/clickstream data (typically JSON from Kafka/Kinesis)
CREATE STAGE IF NOT EXISTS RAW_DB.S3_RAW.STG_S3_EVENTS
    STORAGE_INTEGRATION = S3_RAW_INTEGRATION
    URL                 = 's3://<YOUR_BUCKET_NAME>/raw/events/'
    FILE_FORMAT         = RAW_DB.S3_RAW.FF_JSON
    COMMENT             = 'JSON event stream data from Kinesis Firehose.';

-- Financial transactions (Parquet from data lake)
CREATE STAGE IF NOT EXISTS RAW_DB.S3_RAW.STG_S3_TRANSACTIONS
    STORAGE_INTEGRATION = S3_RAW_INTEGRATION
    URL                 = 's3://<YOUR_BUCKET_NAME>/raw/transactions/'
    FILE_FORMAT         = RAW_DB.S3_RAW.FF_PARQUET
    COMMENT             = 'Parquet transaction files from upstream data lake.';

GRANT USAGE ON ALL STAGES IN SCHEMA RAW_DB.S3_RAW TO ROLE LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- LANDING TABLES FOR SNOWPIPE
-- Ingest into a VARIANT landing table for schema flexibility,
-- then apply typed projection in the bronze dbt models.
-- ---------------------------------------------------------------------------

-- Customer events landing table.
-- NOTE: METADATA$ columns cannot be used as table DEFAULTs — they only exist
-- when querying a stage. The pipes below populate file_name/file_row_number
-- explicitly in their COPY SELECT list.
CREATE TABLE IF NOT EXISTS RAW_DB.S3_RAW.EVENTS_LANDING (
    raw_payload         VARIANT,
    file_name           VARCHAR(1000),
    file_row_number     NUMBER,
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 7
COMMENT = 'Snowpipe landing table for raw JSON event files from S3.';

-- Transactions landing table (Parquet inferred schema)
CREATE TABLE IF NOT EXISTS RAW_DB.S3_RAW.TRANSACTIONS_LANDING (
    raw_payload         VARIANT,
    file_name           VARCHAR(1000),
    file_row_number     NUMBER,
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 7
COMMENT = 'Snowpipe landing table for raw Parquet transaction files from S3.';

GRANT INSERT, SELECT ON TABLE RAW_DB.S3_RAW.EVENTS_LANDING        TO ROLE LOADER_ROLE;
GRANT INSERT, SELECT ON TABLE RAW_DB.S3_RAW.TRANSACTIONS_LANDING  TO ROLE LOADER_ROLE;
GRANT SELECT ON TABLE RAW_DB.S3_RAW.EVENTS_LANDING        TO ROLE TRANSFORMER_ROLE;
GRANT SELECT ON TABLE RAW_DB.S3_RAW.TRANSACTIONS_LANDING  TO ROLE TRANSFORMER_ROLE;

-- ---------------------------------------------------------------------------
-- SNOWPIPE DEFINITIONS (auto-ingest via SQS)
-- ---------------------------------------------------------------------------

-- After creating each pipe, run: DESC PIPE <pipe_name>;
-- Copy the notification_channel SQS ARN and configure in S3 bucket:
--   S3 bucket → Properties → Event notifications → Add notification
--   Event type: s3:ObjectCreated:*  |  Prefix: raw/events/
--   Destination: SQS queue → paste the ARN

CREATE PIPE IF NOT EXISTS RAW_DB.S3_RAW.PIPE_S3_EVENTS
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingest JSON events from S3 into EVENTS_LANDING.'
AS
    COPY INTO RAW_DB.S3_RAW.EVENTS_LANDING (raw_payload, file_name, file_row_number)
    FROM (
        SELECT
            $1,
            METADATA$FILENAME,
            METADATA$FILE_ROW_NUMBER
        FROM @RAW_DB.S3_RAW.STG_S3_EVENTS
    )
    FILE_FORMAT = (FORMAT_NAME = RAW_DB.S3_RAW.FF_JSON);

CREATE PIPE IF NOT EXISTS RAW_DB.S3_RAW.PIPE_S3_TRANSACTIONS
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingest Parquet transactions from S3 into TRANSACTIONS_LANDING.'
AS
    COPY INTO RAW_DB.S3_RAW.TRANSACTIONS_LANDING (raw_payload, file_name, file_row_number)
    FROM (
        SELECT
            $1,
            METADATA$FILENAME,
            METADATA$FILE_ROW_NUMBER
        FROM @RAW_DB.S3_RAW.STG_S3_TRANSACTIONS
    )
    FILE_FORMAT = (FORMAT_NAME = RAW_DB.S3_RAW.FF_PARQUET);

GRANT OPERATE, MONITOR ON PIPE RAW_DB.S3_RAW.PIPE_S3_EVENTS        TO ROLE LOADER_ROLE;
GRANT OPERATE, MONITOR ON PIPE RAW_DB.S3_RAW.PIPE_S3_TRANSACTIONS  TO ROLE LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- MANUAL COPY COMMAND (for backfill / ad-hoc loads)
-- ---------------------------------------------------------------------------

-- COPY INTO RAW_DB.S3_RAW.EVENTS_LANDING (raw_payload, file_name, file_row_number)
-- FROM (
--     SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
--     FROM @RAW_DB.S3_RAW.STG_S3_EVENTS
-- )
-- FILE_FORMAT = (FORMAT_NAME = RAW_DB.S3_RAW.FF_JSON)
-- PATTERN = '.*2024-01-15.*\.json'  -- Load a specific date's files
-- ON_ERROR = CONTINUE
-- PURGE = FALSE;                    -- Do NOT delete source files after load
