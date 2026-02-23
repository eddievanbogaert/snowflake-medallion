{{
    config(
        materialized        = 'incremental',
        unique_key          = 'order_item_id',
        incremental_strategy = 'merge',
        tags                = ['silver', 'orders']
    )
}}

/*
    Silver layer: slv_order_items
    ================================
    Conformed, validated order line items. Grain: one row per order line item.

    Transformations:
      - Type casting
      - Derived: net_line_total (after discount), gross_margin
      - Data quality flags for negative quantities or prices
*/

WITH source AS (

    SELECT * FROM {{ ref('brz_sqlserver_order_items') }}

    {% if is_incremental() %}
    WHERE {{ incremental_date_filter('updated_at') }}
    {% endif %}

),

products AS (

    -- Join silver products for cost lookup (to compute line-level margin)
    SELECT product_id, unit_cost, list_price
    FROM {{ ref('slv_products') }}

),

typed AS (

    SELECT
        -- PK
        CAST(oi.order_item_id AS BIGINT)                                AS order_item_id,

        -- FKs
        CAST(oi.order_id AS BIGINT)                                     AS order_id,
        CAST(oi.product_id AS INTEGER)                                  AS product_id,

        -- Quantities
        CAST(oi.quantity AS INTEGER)                                    AS quantity,

        -- Prices (cast; guard against NULL/non-numeric source values)
        COALESCE(TRY_TO_NUMBER(oi.unit_price::VARCHAR, 18, 2), 0)       AS unit_price,
        COALESCE(TRY_TO_NUMBER(oi.discount_pct::VARCHAR, 5, 2), 0)      AS discount_pct,

        -- Derived: line total after discount
        COALESCE(TRY_TO_NUMBER(oi.line_total::VARCHAR, 18, 2), 0)       AS line_total,

        -- Cross-check: re-derived net total from unit price × qty × (1 - discount)
        ROUND(
            COALESCE(TRY_TO_NUMBER(oi.quantity::VARCHAR), 0)
            * COALESCE(TRY_TO_NUMBER(oi.unit_price::VARCHAR, 18, 2), 0)
            * (1 - COALESCE(TRY_TO_NUMBER(oi.discount_pct::VARCHAR, 5, 2), 0) / 100),
            2
        )                                                               AS computed_net_line_total,

        -- Gross margin per line (requires silver product cost)
        CASE
            WHEN p.unit_cost IS NOT NULL
            THEN ROUND(
                (COALESCE(TRY_TO_NUMBER(oi.line_total::VARCHAR, 18, 2), 0))
                - (p.unit_cost * COALESCE(TRY_TO_NUMBER(oi.quantity::VARCHAR), 0)),
                2)
        END                                                             AS gross_margin,

        -- Data quality flags
        CASE
            WHEN COALESCE(TRY_TO_NUMBER(oi.quantity::VARCHAR), 0) <= 0
            THEN TRUE ELSE FALSE
        END                                                             AS _dq_zero_or_negative_qty,

        CASE
            WHEN COALESCE(TRY_TO_NUMBER(oi.unit_price::VARCHAR, 18, 2), 0) < 0
            THEN TRUE ELSE FALSE
        END                                                             AS _dq_negative_price,

        -- Source timestamps
        {{ safe_cast_timestamp('oi.created_at') }}                      AS created_at,
        {{ safe_cast_timestamp('oi.updated_at') }}                      AS updated_at,
        oi._fivetran_synced                                             AS source_synced_at,

        -- Audit
        {{ audit_columns() }}

    FROM source oi
    LEFT JOIN products p ON p.product_id = CAST(oi.product_id AS INTEGER)

)

SELECT * FROM typed
