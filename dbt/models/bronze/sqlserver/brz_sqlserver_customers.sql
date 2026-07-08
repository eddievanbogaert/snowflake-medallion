{{
    config(
        materialized = 'view',
        tags         = ['bronze', 'sqlserver', 'customers'],
        meta         = {
            'owner': 'data-engineering',
            'source_system': 'SQL Server',
            'description': 'Bronze view over Fivetran-managed SQL Server customer table. No transforms applied.'
        }
    )
}}

/*
    Bronze layer: brz_sqlserver_customers
    ======================================
    A thin, non-transforming view over the Fivetran-managed raw customer table.
    The only logic allowed in bronze:
      - SELECT with explicit column list (documents the schema)
      - Exclude hard-deleted rows flagged by Fivetran (_fivetran_deleted = TRUE)
      - Add metadata columns for lineage

    All data type casting, null handling, and business logic lives in the silver layer.
*/

SELECT
    -- Source natural key
    customer_id,

    -- Demographics
    first_name,
    last_name,
    email_address,
    phone_number,
    date_of_birth,
    gender,

    -- Address
    address_line_1,
    address_line_2,
    city,
    state_province,
    postal_code,
    country_code,

    -- Lifecycle
    customer_status,
    acquisition_channel,

    -- Source timestamps
    created_at,
    updated_at,

    -- Fivetran metadata
    _fivetran_synced,
    _fivetran_deleted,
    _fivetran_id

FROM {{ source('sqlserver_raw', 'customers') }}

-- Exclude soft-deletes from active views (soft-deleted rows are handled in silver via SCD snapshot)
WHERE (_fivetran_deleted IS NULL OR _fivetran_deleted = FALSE)
