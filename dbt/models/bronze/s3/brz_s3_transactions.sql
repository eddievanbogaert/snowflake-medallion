{{
    config(
        materialized = 'view',
        tags         = ['bronze', 's3', 'transactions']
    )
}}

/*
    Bronze layer: brz_s3_transactions
    ====================================
    Extracts typed fields from the Parquet VARIANT payload loaded by Snowpipe.
    Parquet field names are preserved as-is from the source schema.
*/

SELECT
    -- Metadata
    file_name                                                       AS _source_file,
    file_row_number                                                 AS _source_row,
    loaded_at                                                       AS _loaded_at,

    -- Transaction identity
    raw_payload:transaction_id::VARCHAR                             AS transaction_id,
    raw_payload:transaction_type::VARCHAR                           AS transaction_type,
    raw_payload:transaction_status::VARCHAR                         AS transaction_status,

    -- Relationships
    raw_payload:order_id::VARCHAR                                   AS order_id,
    raw_payload:customer_id::VARCHAR                                AS customer_id,
    raw_payload:account_id::VARCHAR                                 AS account_id,

    -- Financial values (kept as strings; cast in silver to DECIMAL)
    raw_payload:amount::VARCHAR                                     AS amount_raw,
    raw_payload:currency_code::VARCHAR                              AS currency_code,
    raw_payload:exchange_rate::VARCHAR                              AS exchange_rate_raw,
    raw_payload:amount_usd::VARCHAR                                 AS amount_usd_raw,
    raw_payload:fee_amount::VARCHAR                                 AS fee_amount_raw,
    raw_payload:tax_amount::VARCHAR                                 AS tax_amount_raw,

    -- Payment details
    raw_payload:payment_method::VARCHAR                             AS payment_method,
    raw_payload:payment_provider::VARCHAR                           AS payment_provider,
    raw_payload:card_last4::VARCHAR                                 AS card_last4,
    raw_payload:card_brand::VARCHAR                                 AS card_brand,

    -- Timestamps
    raw_payload:initiated_at::VARCHAR                               AS initiated_at_raw,
    raw_payload:settled_at::VARCHAR                                 AS settled_at_raw,
    raw_payload:failed_at::VARCHAR                                  AS failed_at_raw,

    -- Provider reference
    raw_payload:provider_reference_id::VARCHAR                      AS provider_reference_id,
    raw_payload:failure_reason::VARCHAR                             AS failure_reason,

    -- Full payload
    raw_payload                                                     AS raw_payload

FROM {{ source('s3_raw', 'transactions_landing') }}
