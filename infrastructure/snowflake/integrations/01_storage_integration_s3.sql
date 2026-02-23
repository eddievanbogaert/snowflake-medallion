-- =============================================================================
-- 01_storage_integration_s3.sql
-- Creates a Snowflake Storage Integration for AWS S3.
--
-- A Storage Integration is the preferred (and most secure) way to connect
-- Snowflake to S3 — it creates an IAM role in Snowflake's AWS account that
-- you then trust from your own AWS IAM policy.
-- This avoids storing long-lived AWS access keys in Snowflake.
--
-- SETUP ORDER:
--   1. Run this script to create the integration and retrieve the
--      STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID values.
--   2. Create the AWS IAM role in your account with a trust policy that
--      allows the Snowflake IAM user ARN to assume it (see commented policy below).
--   3. Update the STORAGE_INTEGRATION to point to the role ARN.
--   4. Create stages using this integration (see 02_external_stages.sql).
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------------
-- STORAGE INTEGRATION
-- ---------------------------------------------------------------------------

CREATE STORAGE INTEGRATION IF NOT EXISTS S3_RAW_INTEGRATION
    TYPE                      = EXTERNAL_STAGE
    STORAGE_PROVIDER          = 'S3'
    ENABLED                   = TRUE
    STORAGE_AWS_ROLE_ARN      = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-s3-access-role'
    STORAGE_ALLOWED_LOCATIONS = (
        's3://<YOUR_BUCKET_NAME>/raw/',          -- Raw ingestion prefix
        's3://<YOUR_BUCKET_NAME>/archive/'       -- Archive prefix
    )
    -- Optionally restrict which prefixes Snowflake CANNOT access
    -- STORAGE_BLOCKED_LOCATIONS = ('s3://<YOUR_BUCKET_NAME>/restricted/')
    COMMENT = 'S3 storage integration for raw data ingestion. Uses IAM role assumption.';

-- ---------------------------------------------------------------------------
-- RETRIEVE THE SNOWFLAKE IAM USER ARN
-- Run this after creating the integration to get the values for the AWS trust policy.
-- ---------------------------------------------------------------------------

-- DESC INTEGRATION S3_RAW_INTEGRATION;
-- Note the values:
--   STORAGE_AWS_IAM_USER_ARN  = arn:aws:iam::123456789012:user/xxxx (Snowflake's user)
--   STORAGE_AWS_EXTERNAL_ID   = MYACCOUNT_SFCRole=2_abc123...

-- ---------------------------------------------------------------------------
-- AWS IAM TRUST POLICY (apply to the 'snowflake-s3-access-role' in AWS console)
-- Replace placeholder values with the output of DESC INTEGRATION above.
-- ---------------------------------------------------------------------------
/*
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::123456789012:user/xxxx"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "sts:ExternalId": "MYACCOUNT_SFCRole=2_abc123..."
                }
            }
        }
    ]
}
*/

-- ---------------------------------------------------------------------------
-- AWS IAM ROLE PERMISSION POLICY (attach to the same role)
-- Grant the minimum permissions needed: s3:GetObject, s3:ListBucket, s3:PutObject
-- for the specific bucket prefix only.
-- ---------------------------------------------------------------------------
/*
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:GetObjectVersion"
            ],
            "Resource": "arn:aws:s3:::<YOUR_BUCKET_NAME>/raw/*"
        },
        {
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::<YOUR_BUCKET_NAME>",
            "Condition": {
                "StringLike": {
                    "s3:prefix": ["raw/*", "archive/*"]
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::<YOUR_BUCKET_NAME>/archive/*"
        }
    ]
}
*/

-- ---------------------------------------------------------------------------
-- GRANT INTEGRATION USAGE TO LOADER ROLE (for stage creation)
-- ---------------------------------------------------------------------------

GRANT USAGE ON INTEGRATION S3_RAW_INTEGRATION TO ROLE LOADER_ROLE;
GRANT USAGE ON INTEGRATION S3_RAW_INTEGRATION TO ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- SQS NOTIFICATION INTEGRATION (for Snowpipe auto-ingest via S3 event notifications)
-- ---------------------------------------------------------------------------

-- Snowpipe can auto-trigger when files arrive in S3 via SQS notifications.
-- After creating the pipe (see 02_external_stages.sql), Snowflake provides
-- an SQS queue ARN — configure S3 bucket notifications to send to that ARN.

-- DESC PIPE RAW_DB.S3_RAW.PIPE_S3_EVENTS;
-- Note: notification_channel = the SQS ARN to configure in S3 bucket notifications
