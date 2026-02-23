{{
    config(
        materialized        = 'incremental',
        unique_key          = 'event_id',
        incremental_strategy = 'merge',
        cluster_by          = ['event_date'],
        tags                = ['silver', 'events']
    )
}}

/*
    Silver layer: slv_events
    ==========================
    Typed, validated event stream from the S3 JSON landing table.
    Clustered by event_date to support efficient date-range queries
    common in product analytics and funnel analysis.

    Transformations:
      - JSON fields cast to typed columns
      - Timestamps parsed to TIMESTAMP_NTZ
      - Deduplication on event_id (Kinesis can produce duplicates)
      - Bot/internal traffic filtered
      - Derived: event_date, hour_of_day, is_authenticated
*/

WITH source AS (

    SELECT * FROM {{ ref('brz_s3_events') }}

    {% if is_incremental() %}
    WHERE {{ incremental_date_filter('_loaded_at') }}
    {% endif %}

),

deduplicated AS (

    -- Kinesis/Firehose may deliver the same event twice; keep first occurrence
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY event_id
               ORDER BY _loaded_at ASC
           ) AS _row_num
    FROM source
    WHERE event_id IS NOT NULL  -- Events without IDs cannot be reliably deduplicated

),

typed AS (

    SELECT
        event_id,
        event_type,
        COALESCE(event_version, '1.0')                          AS event_version,

        -- Parse timestamps; fall back to server_timestamp if event_timestamp is null
        COALESCE(
            {{ safe_cast_timestamp('event_timestamp_raw') }},
            {{ safe_cast_timestamp('server_timestamp_raw') }}
        )                                                       AS event_timestamp,

        -- Derived date parts (used for clustering and partitioning)
        COALESCE(
            TRY_TO_TIMESTAMP_NTZ(event_timestamp_raw)::DATE,
            TRY_TO_TIMESTAMP_NTZ(server_timestamp_raw)::DATE
        )                                                       AS event_date,

        DATE_PART('hour',
            COALESCE(
                TRY_TO_TIMESTAMP_NTZ(event_timestamp_raw),
                TRY_TO_TIMESTAMP_NTZ(server_timestamp_raw)
            )
        )                                                       AS hour_of_day,

        -- User identity
        {{ empty_string_to_null('session_id') }}                AS session_id,
        {{ empty_string_to_null('user_id') }}                   AS user_id,
        {{ empty_string_to_null('anonymous_id') }}              AS anonymous_id,

        -- Derived: is the user logged in?
        CASE WHEN user_id IS NOT NULL THEN TRUE ELSE FALSE END  AS is_authenticated,

        -- Device / platform
        UPPER({{ empty_string_to_null('device_type') }})        AS device_type,
        UPPER({{ empty_string_to_null('platform') }})           AS platform,
        {{ empty_string_to_null('os_name') }}                   AS os_name,
        {{ empty_string_to_null('app_version') }}               AS app_version,

        -- Network (PII — IP address masked per masking policy)
        ip_address,

        -- Geography
        UPPER({{ empty_string_to_null('geo_country_code') }})   AS geo_country_code,
        {{ empty_string_to_null('geo_region') }}                AS geo_region,
        {{ empty_string_to_null('geo_city') }}                  AS geo_city,

        -- Page context
        {{ empty_string_to_null('page_url') }}                  AS page_url,
        {{ empty_string_to_null('page_path') }}                 AS page_path,
        {{ empty_string_to_null('page_referrer') }}             AS page_referrer,
        {{ empty_string_to_null('page_title') }}                AS page_title,

        -- Event-specific properties (keep as VARIANT for flexibility)
        properties,

        -- Source metadata
        _source_file,
        _source_row,
        _loaded_at,

        -- Audit
        {{ audit_columns() }}

    FROM deduplicated
    WHERE _row_num = 1
      -- Filter bot/internal traffic
      AND NOT (
            LOWER(COALESCE(user_agent, '')) ILIKE '%bot%'
         OR LOWER(COALESCE(user_agent, '')) ILIKE '%crawler%'
         OR LOWER(COALESCE(user_agent, '')) ILIKE '%spider%'
         OR ip_address LIKE '10.%'          -- Internal RFC1918 traffic
         OR ip_address LIKE '192.168.%'
      )
      -- Reject events with no usable timestamp
      AND (
          TRY_TO_TIMESTAMP_NTZ(event_timestamp_raw) IS NOT NULL
          OR TRY_TO_TIMESTAMP_NTZ(server_timestamp_raw) IS NOT NULL
      )

)

SELECT * FROM typed
