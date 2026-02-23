-- =============================================================================
-- 01_object_tags.sql
-- Creates Snowflake Object Tags for data classification and governance.
-- Tags are applied to tables and columns to drive masking policies and
-- inform downstream data catalogues (e.g. Collibra, Alation, Snowflake Horizon).
--
-- Run as: ACCOUNTADMIN (tag creation requires ACCOUNTADMIN in most editions)
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MONITORING_DB;
USE SCHEMA AUDIT;

-- ---------------------------------------------------------------------------
-- TAG DEFINITIONS
-- ---------------------------------------------------------------------------

-- Data Sensitivity Classification
CREATE TAG IF NOT EXISTS MONITORING_DB.AUDIT.DATA_SENSITIVITY
    ALLOWED_VALUES = 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED'
    COMMENT = 'Classifies data sensitivity. Drives column masking and access policies.';

-- PII Category — tracks what kind of personal data is in a column
CREATE TAG IF NOT EXISTS MONITORING_DB.AUDIT.PII_CATEGORY
    ALLOWED_VALUES =
        'NONE',
        'NAME',
        'EMAIL',
        'PHONE',
        'ADDRESS',
        'DATE_OF_BIRTH',
        'NATIONAL_ID',           -- SSN, NIN, passport number
        'FINANCIAL',             -- account numbers, card numbers
        'HEALTH',                -- PHI / medical data
        'BIOMETRIC',
        'IP_ADDRESS',
        'DEVICE_ID'
    COMMENT = 'PII category for GDPR/CCPA compliance. Drives dynamic masking policies.';

-- Regulatory compliance scope
CREATE TAG IF NOT EXISTS MONITORING_DB.AUDIT.COMPLIANCE_SCOPE
    ALLOWED_VALUES = 'GDPR', 'CCPA', 'PCI_DSS', 'HIPAA', 'SOC2', 'NONE'
    COMMENT = 'Regulatory frameworks this data falls under.';

-- Source system lineage
CREATE TAG IF NOT EXISTS MONITORING_DB.AUDIT.SOURCE_SYSTEM
    ALLOWED_VALUES = 'SQLSERVER', 'S3', 'SNOWFLAKE_NATIVE', 'MANUAL', 'DERIVED'
    COMMENT = 'Tracks the originating system for this table or column.';

-- Data domain
CREATE TAG IF NOT EXISTS MONITORING_DB.AUDIT.DATA_DOMAIN
    ALLOWED_VALUES = 'CUSTOMER', 'ORDER', 'PRODUCT', 'FINANCE', 'MARKETING', 'OPERATIONS', 'REFERENCE'
    COMMENT = 'Business domain classification for data governance catalogue.';

-- Data product layer
CREATE TAG IF NOT EXISTS MONITORING_DB.AUDIT.MEDALLION_LAYER
    ALLOWED_VALUES = 'BRONZE', 'SILVER', 'GOLD'
    COMMENT = 'Medallion architecture layer this object belongs to.';

-- ---------------------------------------------------------------------------
-- GRANT TAG USAGE to roles that need to set/read tags
-- ---------------------------------------------------------------------------

USE ROLE SECURITYADMIN;

GRANT APPLY TAG ON ACCOUNT TO ROLE ACCOUNTADMIN;
GRANT APPLY TAG ON ACCOUNT TO ROLE SYSADMIN;

-- Allow TRANSFORMER_ROLE to read tag values (needed for masking policy evaluation)
GRANT USAGE ON DATABASE MONITORING_DB TO ROLE TRANSFORMER_ROLE;
GRANT USAGE ON SCHEMA MONITORING_DB.AUDIT TO ROLE TRANSFORMER_ROLE;

-- ---------------------------------------------------------------------------
-- EXAMPLE TAG APPLICATIONS
-- Apply tags during table DDL or after creation.
-- Shown here as post-creation examples to illustrate the pattern.
-- ---------------------------------------------------------------------------

-- Apply medallion layer tags to databases (once they exist)
-- ALTER DATABASE RAW_DB        SET TAG MONITORING_DB.AUDIT.MEDALLION_LAYER = 'BRONZE';
-- ALTER DATABASE FOUNDATION_DB SET TAG MONITORING_DB.AUDIT.MEDALLION_LAYER = 'SILVER';
-- ALTER DATABASE ANALYTICS_DB  SET TAG MONITORING_DB.AUDIT.MEDALLION_LAYER = 'GOLD';

-- Example: tag a customer table as CONFIDENTIAL + GDPR in scope
-- ALTER TABLE FOUNDATION_DB.CUSTOMERS.CUSTOMERS
--     SET TAG MONITORING_DB.AUDIT.DATA_SENSITIVITY = 'CONFIDENTIAL',
--             MONITORING_DB.AUDIT.COMPLIANCE_SCOPE  = 'GDPR',
--             MONITORING_DB.AUDIT.DATA_DOMAIN        = 'CUSTOMER';

-- Example: tag email column as PII
-- ALTER TABLE FOUNDATION_DB.CUSTOMERS.CUSTOMERS
--     MODIFY COLUMN EMAIL
--     SET TAG MONITORING_DB.AUDIT.PII_CATEGORY = 'EMAIL',
--             MONITORING_DB.AUDIT.DATA_SENSITIVITY = 'CONFIDENTIAL';

-- ---------------------------------------------------------------------------
-- VIEW: TAG INVENTORY
-- Provides a queryable inventory of all tagged objects — useful for audits.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW MONITORING_DB.AUDIT.VW_TAG_INVENTORY AS
SELECT
    tag_database,
    tag_schema,
    tag_name,
    tag_value,
    object_database,
    object_schema,
    object_name,
    object_type,
    column_name,
    CURRENT_TIMESTAMP AS report_timestamp
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE tag_database = 'MONITORING_DB'
ORDER BY object_database, object_schema, object_name, column_name;

GRANT SELECT ON VIEW MONITORING_DB.AUDIT.VW_TAG_INVENTORY TO ROLE DATA_ENGINEER_ROLE;
