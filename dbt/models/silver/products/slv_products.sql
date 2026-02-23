{{
    config(
        materialized        = 'incremental',
        unique_key          = 'product_id',
        incremental_strategy = 'merge',
        tags                = ['silver', 'products']
    )
}}

/*
    Silver layer: slv_products
    ============================
    Conformed, validated product catalogue from the SQL Server bronze source.

    Transformations:
      - Type casting (all columns to final types)
      - NULL handling and string normalisation
      - Derived: margin_pct, is_discounted
      - Status filtering: soft-deleted products remain but are flagged is_active = FALSE
*/

WITH source AS (

    SELECT * FROM {{ ref('brz_sqlserver_products') }}

    {% if is_incremental() %}
    WHERE {{ incremental_date_filter('updated_at') }}
    {% endif %}

),

deduplicated AS (

    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY product_id
               ORDER BY _fivetran_synced DESC, updated_at DESC NULLS LAST
           ) AS _row_num
    FROM source

),

typed AS (

    SELECT
        -- PK
        CAST(product_id AS INTEGER)                                     AS product_id,

        -- Identifiers
        {{ empty_string_to_null('TRIM(sku)') }}                         AS sku,
        {{ empty_string_to_null('TRIM(product_name)') }}                AS product_name,
        {{ empty_string_to_null('TRIM(product_description)') }}         AS product_description,

        -- Category hierarchy
        CAST(category_id AS INTEGER)                                    AS category_id,
        INITCAP({{ empty_string_to_null('TRIM(category_name)') }})      AS category_name,

        -- Brand
        CAST(brand_id AS INTEGER)                                       AS brand_id,
        INITCAP({{ empty_string_to_null('TRIM(brand_name)') }})         AS brand_name,

        -- Pricing (cast from DECIMAL; already typed in source but guard with TRY)
        COALESCE(TRY_TO_NUMBER(unit_cost::VARCHAR, 18, 4), 0)           AS unit_cost,
        COALESCE(TRY_TO_NUMBER(list_price::VARCHAR, 18, 2), 0)          AS list_price,

        -- Derived: gross margin percentage at list price
        CASE
            WHEN TRY_TO_NUMBER(list_price::VARCHAR, 18, 2) > 0
            THEN ROUND(
                (TRY_TO_NUMBER(list_price::VARCHAR, 18, 2)
                 - TRY_TO_NUMBER(unit_cost::VARCHAR, 18, 4))
                / TRY_TO_NUMBER(list_price::VARCHAR, 18, 2) * 100, 2)
            ELSE NULL
        END                                                             AS list_margin_pct,

        -- Physical attributes
        TRY_TO_NUMBER(weight_kg::VARCHAR, 10, 3)                        AS weight_kg,

        -- Status
        COALESCE(is_active, FALSE)                                      AS is_active,

        -- Data quality flags
        CASE
            WHEN TRY_TO_NUMBER(list_price::VARCHAR) IS NULL
                 OR TRY_TO_NUMBER(list_price::VARCHAR) <= 0
            THEN TRUE ELSE FALSE
        END                                                             AS _dq_invalid_price,

        CASE
            WHEN TRY_TO_NUMBER(unit_cost::VARCHAR) IS NULL
                 OR TRY_TO_NUMBER(unit_cost::VARCHAR) < 0
            THEN TRUE ELSE FALSE
        END                                                             AS _dq_invalid_cost,

        -- Source timestamps
        {{ safe_cast_timestamp('created_at') }}                         AS created_at,
        {{ safe_cast_timestamp('updated_at') }}                         AS updated_at,
        _fivetran_synced                                                AS source_synced_at,

        -- Audit
        {{ audit_columns() }}

    FROM deduplicated
    WHERE _row_num = 1
      AND TRY_TO_NUMBER(product_id::VARCHAR) IS NOT NULL

)

SELECT * FROM typed
