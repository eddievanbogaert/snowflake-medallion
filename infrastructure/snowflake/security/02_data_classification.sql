-- =============================================================================
-- 02_data_classification.sql
-- Demonstrates Snowflake's automated data classification feature and
-- manual classification workflows.
--
-- Snowflake can automatically scan column values and suggest PII categories.
-- This script sets up the classification workflow and stores results.
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MONITORING_DB;
USE SCHEMA AUDIT;

-- ---------------------------------------------------------------------------
-- AUTOMATED CLASSIFICATION
-- Snowflake's built-in ML-based classifier scans column samples and suggests
-- semantic categories (email, phone, SSN, credit card, etc.).
-- Results are stored and can drive automatic tag assignment.
-- ---------------------------------------------------------------------------

-- Run classification on a schema (example — run on each silver schema)
-- Results take a few minutes; check status with SYSTEM$GET_CLASSIFICATION_RESULT.
-- CALL SYSTEM$CLASSIFY_SCHEMA('FOUNDATION_DB.CUSTOMERS', {});
-- CALL SYSTEM$CLASSIFY_SCHEMA('FOUNDATION_DB.ORDERS', {});

-- Apply classification results as tags automatically:
-- CALL SYSTEM$APPLY_CLASSIFICATION_PROFILE('FOUNDATION_DB.CUSTOMERS', {});

-- ---------------------------------------------------------------------------
-- DATA CLASSIFICATION RESULTS TABLE
-- Stores manual and automated classification decisions for audit purposes.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS MONITORING_DB.AUDIT.DATA_CLASSIFICATION_LOG (
    classification_id       NUMBER AUTOINCREMENT PRIMARY KEY,
    classified_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    classified_by           VARCHAR(255) DEFAULT CURRENT_USER(),
    database_name           VARCHAR(255) NOT NULL,
    schema_name             VARCHAR(255) NOT NULL,
    table_name              VARCHAR(255) NOT NULL,
    column_name             VARCHAR(255),                      -- NULL = table-level classification
    pii_category            VARCHAR(100),
    data_sensitivity        VARCHAR(50),
    compliance_scope        VARCHAR(255),                      -- comma-separated if multiple
    classification_method   VARCHAR(50) DEFAULT 'MANUAL',      -- MANUAL, AUTOMATED, REVIEWED
    notes                   VARCHAR(2000),
    approved_by             VARCHAR(255),
    approved_at             TIMESTAMP_NTZ
);

GRANT INSERT, SELECT ON TABLE MONITORING_DB.AUDIT.DATA_CLASSIFICATION_LOG
    TO ROLE DATA_ENGINEER_ROLE;

-- ---------------------------------------------------------------------------
-- EXAMPLE CLASSIFICATION ENTRIES (template — adapt to real schema)
-- ---------------------------------------------------------------------------

-- INSERT INTO MONITORING_DB.AUDIT.DATA_CLASSIFICATION_LOG
--     (database_name, schema_name, table_name, column_name,
--      pii_category, data_sensitivity, compliance_scope, classification_method)
-- VALUES
--     ('FOUNDATION_DB', 'CUSTOMERS', 'CUSTOMERS', 'EMAIL_ADDRESS',
--      'EMAIL', 'CONFIDENTIAL', 'GDPR,CCPA', 'MANUAL'),
--
--     ('FOUNDATION_DB', 'CUSTOMERS', 'CUSTOMERS', 'PHONE_NUMBER',
--      'PHONE', 'CONFIDENTIAL', 'GDPR,CCPA', 'MANUAL'),
--
--     ('FOUNDATION_DB', 'CUSTOMERS', 'CUSTOMERS', 'DATE_OF_BIRTH',
--      'DATE_OF_BIRTH', 'RESTRICTED', 'GDPR,CCPA', 'MANUAL'),
--
--     ('FOUNDATION_DB', 'CUSTOMERS', 'CUSTOMERS', 'FULL_NAME',
--      'NAME', 'CONFIDENTIAL', 'GDPR,CCPA', 'MANUAL'),
--
--     ('FOUNDATION_DB', 'ORDERS', 'ORDERS', 'BILLING_CARD_LAST4',
--      'FINANCIAL', 'RESTRICTED', 'PCI_DSS', 'MANUAL');

-- ---------------------------------------------------------------------------
-- VIEW: PII EXPOSURE SUMMARY
-- Identifies which columns in each layer contain PII, for compliance reporting.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_PII_EXPOSURE_SUMMARY AS
SELECT
    dcl.database_name,
    dcl.schema_name,
    dcl.table_name,
    dcl.column_name,
    dcl.pii_category,
    dcl.data_sensitivity,
    dcl.compliance_scope,
    dcl.classification_method,
    dcl.classified_at,
    dcl.approved_by,
    -- Check if a masking policy is applied (join to tag references)
    tr.tag_value AS masking_tag_value,
    CASE
        WHEN tr.tag_value IS NOT NULL THEN 'MASKED'
        ELSE 'UNMASKED — REVIEW REQUIRED'
    END AS masking_status
FROM MONITORING_DB.AUDIT.DATA_CLASSIFICATION_LOG dcl
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tr
    ON  tr.object_database  = dcl.database_name
    AND tr.object_schema    = dcl.schema_name
    AND tr.object_name      = dcl.table_name
    AND tr.column_name      = dcl.column_name
    AND tr.tag_name         = 'PII_CATEGORY'
WHERE dcl.column_name IS NOT NULL
ORDER BY dcl.database_name, dcl.schema_name, dcl.table_name, dcl.column_name;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_PII_EXPOSURE_SUMMARY
    TO ROLE DATA_ENGINEER_ROLE;
