{{
    config(
        materialized = 'view',
        tags         = ['bronze', 's3', 'events']
    )
}}

/*
    Bronze layer: brz_s3_events
    ============================
    Extracts typed fields from the JSON VARIANT payload landed by Snowpipe.
    Keeps the full raw_payload for reprocessing and schema evolution.

    JSON extraction only — no business logic, no nullability assumptions.
    All fields remain nullable; casting to final types happens in silver.
*/

SELECT
    -- Metadata
    file_name                                                       AS _source_file,
    file_row_number                                                 AS _source_row,
    loaded_at                                                       AS _loaded_at,

    -- Event identity
    raw_payload:event_id::VARCHAR                                   AS event_id,
    raw_payload:event_type::VARCHAR                                 AS event_type,
    raw_payload:event_version::VARCHAR                              AS event_version,

    -- Timestamps
    raw_payload:event_timestamp::VARCHAR                            AS event_timestamp_raw,
    raw_payload:server_timestamp::VARCHAR                           AS server_timestamp_raw,

    -- Session / device context
    raw_payload:session_id::VARCHAR                                 AS session_id,
    raw_payload:user_id::VARCHAR                                    AS user_id,
    raw_payload:anonymous_id::VARCHAR                               AS anonymous_id,
    raw_payload:device_type::VARCHAR                                AS device_type,
    raw_payload:platform::VARCHAR                                   AS platform,
    raw_payload:os_name::VARCHAR                                    AS os_name,
    raw_payload:app_version::VARCHAR                                AS app_version,
    raw_payload:ip_address::VARCHAR                                 AS ip_address,
    raw_payload:user_agent::VARCHAR                                 AS user_agent,

    -- Geo context
    raw_payload:geo:country_code::VARCHAR                           AS geo_country_code,
    raw_payload:geo:region::VARCHAR                                 AS geo_region,
    raw_payload:geo:city::VARCHAR                                   AS geo_city,

    -- Page / screen context
    raw_payload:page:url::VARCHAR                                   AS page_url,
    raw_payload:page:path::VARCHAR                                  AS page_path,
    raw_payload:page:referrer::VARCHAR                              AS page_referrer,
    raw_payload:page:title::VARCHAR                                 AS page_title,

    -- Event-specific properties (VARIANT — parsed in silver per event_type)
    raw_payload:properties                                          AS properties,

    -- Full payload retained for reprocessing / schema evolution
    raw_payload                                                     AS raw_payload

FROM {{ source('s3_raw', 'events_landing') }}
