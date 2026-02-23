{{
    config(
        materialized        = 'incremental',
        unique_key          = 'customer_id',
        incremental_strategy = 'merge',
        tags                = ['silver', 'customers'],
        meta                = {
            'owner': 'data-engineering',
            'pii_present': true,
            'pii_columns': ['email_address', 'phone_number', 'date_of_birth', 'full_name'],
            'masking_policy_applied': true
        }
    )
}}

/*
    Silver layer: slv_customers
    ==============================
    Conformed, validated customer entity built from the SQL Server bronze source.

    Transformations applied:
      - Type casting (all columns to final types)
      - NULL handling (empty strings → NULL, impossible dates → NULL)
      - Name standardisation (UPPER/LOWER, TRIM)
      - Derived columns (full_name, age_band)
      - Deduplication (latest record per customer_id via _fivetran_synced)
      - Rejection of records that fail critical data quality checks

    PII columns: email_address, phone_number, date_of_birth, full_name
    Masking policies applied post-creation via 03_column_masking_policies.sql.
*/

WITH source AS (

    SELECT * FROM {{ ref('brz_sqlserver_customers') }}

    {% if is_incremental() %}
    -- Only reprocess records updated within the lookback window
    WHERE {{ incremental_date_filter('updated_at') }}
    {% endif %}

),

deduplicated AS (

    -- Handle duplicate customer_ids by keeping the most recently synced record
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY _fivetran_synced DESC, updated_at DESC NULLS LAST
           ) AS _row_num
    FROM source

),

typed AS (

    SELECT
        -- Primary Key
        CAST(customer_id AS INTEGER)                                AS customer_id,

        -- Name (normalise casing; strip whitespace)
        INITCAP({{ empty_string_to_null('TRIM(first_name)') }})     AS first_name,
        INITCAP({{ empty_string_to_null('TRIM(last_name)') }})      AS last_name,

        -- Derived: full name for display
        TRIM(
            COALESCE(INITCAP(TRIM(first_name)), '') || ' ' ||
            COALESCE(INITCAP(TRIM(last_name)), '')
        )                                                           AS full_name,

        -- Contact (normalise case; reject obviously invalid emails)
        LOWER({{ empty_string_to_null('TRIM(email_address)') }})    AS email_address,
        {{ empty_string_to_null('TRIM(phone_number)') }}            AS phone_number,

        -- Demographics
        {{ safe_cast_date('date_of_birth') }}                       AS date_of_birth,

        -- Derived age band (for analytics — does not expose exact age)
        CASE
            WHEN TRY_TO_DATE(date_of_birth) IS NULL THEN 'UNKNOWN'
            WHEN DATEDIFF('year', TRY_TO_DATE(date_of_birth), CURRENT_DATE()) < 18  THEN 'UNDER_18'
            WHEN DATEDIFF('year', TRY_TO_DATE(date_of_birth), CURRENT_DATE()) < 25  THEN '18_24'
            WHEN DATEDIFF('year', TRY_TO_DATE(date_of_birth), CURRENT_DATE()) < 35  THEN '25_34'
            WHEN DATEDIFF('year', TRY_TO_DATE(date_of_birth), CURRENT_DATE()) < 45  THEN '35_44'
            WHEN DATEDIFF('year', TRY_TO_DATE(date_of_birth), CURRENT_DATE()) < 55  THEN '45_54'
            WHEN DATEDIFF('year', TRY_TO_DATE(date_of_birth), CURRENT_DATE()) < 65  THEN '55_64'
            ELSE '65_PLUS'
        END                                                         AS age_band,

        UPPER({{ empty_string_to_null('TRIM(gender)') }})           AS gender,

        -- Address
        {{ empty_string_to_null('TRIM(address_line_1)') }}          AS address_line_1,
        {{ empty_string_to_null('TRIM(address_line_2)') }}          AS address_line_2,
        INITCAP({{ empty_string_to_null('TRIM(city)') }})           AS city,
        {{ empty_string_to_null('TRIM(state_province)') }}          AS state_province,
        {{ empty_string_to_null('TRIM(postal_code)') }}             AS postal_code,
        UPPER({{ empty_string_to_null('TRIM(country_code)') }})     AS country_code,

        -- Lifecycle
        UPPER({{ empty_string_to_null('TRIM(customer_status)') }})  AS customer_status,
        UPPER({{ empty_string_to_null('TRIM(acquisition_channel)') }}) AS acquisition_channel,

        -- Source timestamps (cast to TIMESTAMP_NTZ)
        {{ safe_cast_timestamp('created_at') }}                     AS created_at,
        {{ safe_cast_timestamp('updated_at') }}                     AS updated_at,
        _fivetran_synced                                            AS source_synced_at,

        -- Data quality flags (visible to engineers; masked for analysts)
        CASE
            WHEN email_address IS NOT NULL
                 AND NOT (TRIM(email_address) RLIKE '.+@.+\\..+')
            THEN TRUE
            ELSE FALSE
        END                                                         AS _dq_invalid_email,

        CASE
            WHEN TRY_TO_DATE(date_of_birth) IS NOT NULL
                 AND TRY_TO_DATE(date_of_birth) > CURRENT_DATE()
            THEN TRUE
            ELSE FALSE
        END                                                         AS _dq_future_dob,

        -- Audit columns
        {{ audit_columns() }}

    FROM deduplicated
    WHERE _row_num = 1
      -- Hard reject: customer_id must be a valid integer
      AND TRY_TO_NUMBER(customer_id::VARCHAR) IS NOT NULL

)

SELECT * FROM typed
