-- =============================================================================
-- 03_sqlserver_integration.sql
-- Templates and patterns for ingesting data from a legacy SQL Server database.
--
-- Three integration patterns are documented:
--
--   PATTERN A: ADF (Azure Data Factory) → S3 → Snowpipe
--     Best for: Azure-hosted SQL Server, scheduled full/incremental extracts.
--     Data lands in S3 as CSV/Parquet → picked up by Snowpipe.
--
--   PATTERN B: Fivetran SQL Server Connector → RAW_DB
--     Best for: managed, low-maintenance CDC with automatic schema change handling.
--     Fivetran writes directly into Snowflake; provides Fivetran audit columns.
--
--   PATTERN C: Snowflake External Table over SQL Server via JDBC
--     Not natively supported — Snowflake does not support JDBC external tables.
--     Use Pattern A or B for production. Pattern C is documented for reference.
--
-- This file configures:
--   - Target tables for Fivetran / ADF loads (Pattern B / A)
--   - Fivetran landing schema conventions
--   - Change data capture (CDC) tracking tables
--
-- Run as: SYSADMIN / LOADER_ROLE
-- =============================================================================

USE ROLE SYSADMIN;
USE DATABASE RAW_DB;
USE SCHEMA SQLSERVER_RAW;

-- ---------------------------------------------------------------------------
-- PATTERN B: FIVETRAN LANDING TABLES
-- Fivetran creates and manages these tables automatically, but we define
-- them here to document the expected schema and apply governance tags.
-- Fivetran adds system columns: _FIVETRAN_SYNCED, _FIVETRAN_DELETED, _FIVETRAN_ID
--
-- NAMING: landing tables carry the plain source names (CUSTOMERS, ORDERS, ...)
-- exactly as Fivetran creates them. The brz_* names belong to the dbt-managed
-- bronze views in RAW_DB.BRONZE — keeping the two distinct avoids collisions
-- between loader-managed tables and dbt-managed views.
-- ---------------------------------------------------------------------------

-- Customers table (matches SQL Server dbo.Customers)
CREATE TABLE IF NOT EXISTS RAW_DB.SQLSERVER_RAW.CUSTOMERS (
    -- Source PK
    customer_id             INTEGER,
    -- Source columns (types should match SQL Server; widths can be wider)
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    email_address           VARCHAR(255),
    phone_number            VARCHAR(50),
    date_of_birth           DATE,
    gender                  VARCHAR(20),
    address_line_1          VARCHAR(255),
    address_line_2          VARCHAR(255),
    city                    VARCHAR(100),
    state_province          VARCHAR(100),
    postal_code             VARCHAR(20),
    country_code            VARCHAR(3),
    customer_status         VARCHAR(50),
    acquisition_channel     VARCHAR(100),
    created_at              TIMESTAMP_NTZ,
    updated_at              TIMESTAMP_NTZ,
    -- Fivetran system columns (managed by Fivetran; do not populate manually)
    _fivetran_synced        TIMESTAMP_NTZ,
    _fivetran_deleted       BOOLEAN,
    _fivetran_id            VARCHAR(100)
)
DATA_RETENTION_TIME_IN_DAYS = 14
COMMENT = 'Raw customer records from SQL Server dbo.Customers. Loaded by Fivetran CDC.';

-- Orders table (matches SQL Server dbo.Orders)
CREATE TABLE IF NOT EXISTS RAW_DB.SQLSERVER_RAW.ORDERS (
    order_id                BIGINT,
    customer_id             INTEGER,
    order_date              TIMESTAMP_NTZ,
    required_date           DATE,
    shipped_date            DATE,
    order_status            VARCHAR(50),
    order_total             DECIMAL(18, 2),
    discount_amount         DECIMAL(18, 2),
    tax_amount              DECIMAL(18, 2),
    currency_code           VARCHAR(3),
    shipping_address_id     INTEGER,
    billing_address_id      INTEGER,
    payment_method          VARCHAR(50),
    notes                   VARCHAR(2000),
    created_at              TIMESTAMP_NTZ,
    updated_at              TIMESTAMP_NTZ,
    -- Fivetran system columns
    _fivetran_synced        TIMESTAMP_NTZ,
    _fivetran_deleted       BOOLEAN,
    _fivetran_id            VARCHAR(100)
)
DATA_RETENTION_TIME_IN_DAYS = 14
COMMENT = 'Raw order records from SQL Server dbo.Orders. Loaded by Fivetran CDC.';

-- Order Line Items
CREATE TABLE IF NOT EXISTS RAW_DB.SQLSERVER_RAW.ORDER_ITEMS (
    order_item_id           BIGINT,
    order_id                BIGINT,
    product_id              INTEGER,
    quantity                INTEGER,
    unit_price              DECIMAL(18, 2),
    discount_pct            DECIMAL(5, 2),
    line_total              DECIMAL(18, 2),
    created_at              TIMESTAMP_NTZ,
    updated_at              TIMESTAMP_NTZ,
    _fivetran_synced        TIMESTAMP_NTZ,
    _fivetran_deleted       BOOLEAN,
    _fivetran_id            VARCHAR(100)
)
DATA_RETENTION_TIME_IN_DAYS = 14
COMMENT = 'Raw order line items from SQL Server dbo.OrderItems.';

-- Products
CREATE TABLE IF NOT EXISTS RAW_DB.SQLSERVER_RAW.PRODUCTS (
    product_id              INTEGER,
    sku                     VARCHAR(100),
    product_name            VARCHAR(500),
    product_description     VARCHAR(4000),
    category_id             INTEGER,
    category_name           VARCHAR(255),
    brand_id                INTEGER,
    brand_name              VARCHAR(255),
    unit_cost               DECIMAL(18, 2),
    list_price              DECIMAL(18, 2),
    weight_kg               DECIMAL(10, 3),
    is_active               BOOLEAN,
    created_at              TIMESTAMP_NTZ,
    updated_at              TIMESTAMP_NTZ,
    _fivetran_synced        TIMESTAMP_NTZ,
    _fivetran_deleted       BOOLEAN,
    _fivetran_id            VARCHAR(100)
)
DATA_RETENTION_TIME_IN_DAYS = 14
COMMENT = 'Raw product catalogue from SQL Server dbo.Products.';

-- Grants
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DB.SQLSERVER_RAW TO ROLE TRANSFORMER_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DB.SQLSERVER_RAW TO ROLE TRANSFORMER_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DB.SQLSERVER_RAW TO ROLE DATA_ENGINEER_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DB.SQLSERVER_RAW TO ROLE DATA_ENGINEER_ROLE;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA RAW_DB.SQLSERVER_RAW TO ROLE LOADER_ROLE;
GRANT INSERT, UPDATE ON FUTURE TABLES IN SCHEMA RAW_DB.SQLSERVER_RAW TO ROLE LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- PATTERN A: ADF COPY ACTIVITY TARGET (direct COPY INTO from S3 stage)
-- ADF exports SQL Server tables to S3 as pipe-delimited CSV.
-- Snowpipe (or scheduled COPY INTO) loads from STG_S3_CUSTOMERS stage.
-- ---------------------------------------------------------------------------

-- Customer CSV table (ADF export — one file per day, partition by date)
-- NOTE: METADATA$ columns cannot be used as table DEFAULTs — they only exist
-- when querying a stage. The COPY task below populates them explicitly.
CREATE TABLE IF NOT EXISTS RAW_DB.SQLSERVER_RAW.ADF_CUSTOMERS (
    customer_id             VARCHAR(20),  -- VARCHAR to avoid load errors on bad data
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    email_address           VARCHAR(255),
    phone_number            VARCHAR(50),
    date_of_birth           VARCHAR(20),  -- String; cast in silver
    gender                  VARCHAR(20),
    address_line_1          VARCHAR(255),
    city                    VARCHAR(100),
    country_code            VARCHAR(3),
    customer_status         VARCHAR(50),
    created_at              VARCHAR(50),
    updated_at              VARCHAR(50),
    -- Bronze metadata (populated by the COPY task)
    _source_file            VARCHAR(1000),
    _source_row             NUMBER,
    _loaded_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _batch_date             DATE          DEFAULT CURRENT_DATE()
)
DATA_RETENTION_TIME_IN_DAYS = 14
COMMENT = 'ADF pipe-delimited CSV extracts from SQL Server. Strings only — cast in silver.';

GRANT INSERT, SELECT ON TABLE RAW_DB.SQLSERVER_RAW.ADF_CUSTOMERS TO ROLE LOADER_ROLE;
GRANT SELECT ON TABLE RAW_DB.SQLSERVER_RAW.ADF_CUSTOMERS TO ROLE TRANSFORMER_ROLE;

-- Scheduled COPY INTO task (runs after ADF delivers files — adjust CRON as needed)
CREATE TASK IF NOT EXISTS RAW_DB.SQLSERVER_RAW.TASK_COPY_ADF_CUSTOMERS
    WAREHOUSE          = INGESTION_WH
    SCHEDULE           = 'USING CRON 0 2 * * * UTC'  -- 02:00 UTC daily
    COMMENT            = 'Loads ADF customer extracts from S3 stage into ADF_CUSTOMERS.'
AS
    COPY INTO RAW_DB.SQLSERVER_RAW.ADF_CUSTOMERS (
        customer_id, first_name, last_name, email_address, phone_number,
        date_of_birth, gender, address_line_1, city, country_code,
        customer_status, created_at, updated_at,
        _source_file, _source_row
    )
    FROM (
        SELECT
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            METADATA$FILENAME,
            METADATA$FILE_ROW_NUMBER
        FROM @RAW_DB.S3_RAW.STG_S3_CUSTOMERS
    )
    FILE_FORMAT = (FORMAT_NAME = RAW_DB.S3_RAW.FF_CSV_PIPE_DELIMITED)
    ON_ERROR = 'CONTINUE'
    PURGE = FALSE;  -- Keep source files for reprocessing

-- Resume the task (tasks start SUSPENDED).
-- The task owner (SYSADMIN here) also needs the account-level EXECUTE TASK
-- privilege before the task will run:
-- USE ROLE ACCOUNTADMIN;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
-- ALTER TASK RAW_DB.SQLSERVER_RAW.TASK_COPY_ADF_CUSTOMERS RESUME;

-- ---------------------------------------------------------------------------
-- INGESTION AUDIT TABLE
-- Tracks every load batch for lineage and debugging.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS RAW_DB.SQLSERVER_RAW.INGESTION_LOG (
    log_id          NUMBER AUTOINCREMENT PRIMARY KEY,
    logged_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    source_system   VARCHAR(100),
    table_name      VARCHAR(255),
    load_method     VARCHAR(50),   -- FIVETRAN, ADF_COPY, SNOWPIPE, MANUAL
    batch_date      DATE,
    rows_loaded     NUMBER,
    rows_rejected   NUMBER,
    file_name       VARCHAR(1000),
    status          VARCHAR(50),   -- SUCCESS, PARTIAL, FAILED
    error_message   VARCHAR(4000)
);

GRANT INSERT, SELECT ON TABLE RAW_DB.SQLSERVER_RAW.INGESTION_LOG TO ROLE LOADER_ROLE;
GRANT SELECT ON TABLE RAW_DB.SQLSERVER_RAW.INGESTION_LOG TO ROLE TRANSFORMER_ROLE;
GRANT SELECT ON TABLE RAW_DB.SQLSERVER_RAW.INGESTION_LOG TO ROLE DATA_ENGINEER_ROLE;
