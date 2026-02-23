{{
    config(
        materialized        = 'incremental',
        unique_key          = 'order_id',
        incremental_strategy = 'merge',
        tags                = ['silver', 'orders']
    )
}}

/*
    Silver layer: slv_orders
    ==========================
    Conformed, validated order entity joined with order items for denormalised totals.

    Transformations:
      - Type casting and NULL handling
      - Amounts validated (no negative totals)
      - Derived order-level aggregates from line items
      - Order status normalised to canonical set
*/

WITH orders_raw AS (

    SELECT * FROM {{ ref('brz_sqlserver_orders') }}

    {% if is_incremental() %}
    WHERE {{ incremental_date_filter('updated_at') }}
    {% endif %}

),

order_items_raw AS (

    SELECT * FROM {{ ref('brz_sqlserver_order_items') }}

),

-- Aggregate line items to order level for cross-checking header totals
order_item_agg AS (

    SELECT
        order_id,
        COUNT(*)                            AS line_item_count,
        SUM(quantity)                       AS total_units,
        SUM(line_total)                     AS computed_order_total,
        SUM(quantity * unit_price)          AS computed_gross_total,
        SUM(quantity * unit_price
            - COALESCE(line_total, 0))      AS computed_discount_total
    FROM order_items_raw
    GROUP BY order_id

),

enriched AS (

    SELECT
        -- PK
        CAST(o.order_id AS BIGINT)                                      AS order_id,
        CAST(o.customer_id AS INTEGER)                                  AS customer_id,

        -- Timestamps
        {{ safe_cast_timestamp('o.order_date') }}                       AS order_date,
        {{ safe_cast_date('o.required_date') }}                         AS required_date,
        {{ safe_cast_date('o.shipped_date') }}                          AS shipped_date,

        -- Derived: days to ship (NULL if not yet shipped or order_date is NULL)
        CASE
            WHEN TRY_TO_DATE(o.shipped_date) IS NOT NULL
                 AND TRY_TO_TIMESTAMP_NTZ(o.order_date) IS NOT NULL
            THEN DATEDIFF('day',
                    TRY_TO_TIMESTAMP_NTZ(o.order_date)::DATE,
                    TRY_TO_DATE(o.shipped_date))
        END                                                             AS days_to_ship,

        -- Status normalisation
        CASE UPPER(TRIM(o.order_status))
            WHEN 'PENDING'      THEN 'PENDING'
            WHEN 'CONFIRMED'    THEN 'CONFIRMED'
            WHEN 'PROCESSING'   THEN 'PROCESSING'
            WHEN 'SHIPPED'      THEN 'SHIPPED'
            WHEN 'DELIVERED'    THEN 'DELIVERED'
            WHEN 'CANCELLED'    THEN 'CANCELLED'
            WHEN 'REFUNDED'     THEN 'REFUNDED'
            WHEN 'RETURNED'     THEN 'RETURNED'
            ELSE 'UNKNOWN'
        END                                                             AS order_status,

        -- Financials (cast, null-safe)
        COALESCE(TRY_TO_NUMBER(o.order_total::VARCHAR, 18, 2), 0)      AS order_total,
        COALESCE(TRY_TO_NUMBER(o.discount_amount::VARCHAR, 18, 2), 0)  AS discount_amount,
        COALESCE(TRY_TO_NUMBER(o.tax_amount::VARCHAR, 18, 2), 0)       AS tax_amount,
        COALESCE(UPPER(TRIM(o.currency_code)), 'USD')                  AS currency_code,

        -- Line item aggregates from order_item_agg
        COALESCE(oia.line_item_count, 0)                               AS line_item_count,
        COALESCE(oia.total_units, 0)                                   AS total_units,
        oia.computed_order_total,

        -- Data quality flags
        CASE
            WHEN TRY_TO_NUMBER(o.order_total::VARCHAR, 18, 2) < 0
            THEN TRUE ELSE FALSE
        END                                                             AS _dq_negative_total,

        CASE
            WHEN oia.computed_order_total IS NOT NULL
                 AND ABS(COALESCE(TRY_TO_NUMBER(o.order_total::VARCHAR, 18, 2), 0)
                         - oia.computed_order_total) > 0.01
            THEN TRUE ELSE FALSE
        END                                                             AS _dq_total_mismatch,

        -- Other fields
        UPPER(TRIM(o.payment_method))                                   AS payment_method,
        {{ empty_string_to_null('o.notes') }}                           AS notes,

        -- Source timestamps
        {{ safe_cast_timestamp('o.created_at') }}                       AS created_at,
        {{ safe_cast_timestamp('o.updated_at') }}                       AS updated_at,
        o._fivetran_synced                                              AS source_synced_at,

        -- Audit
        {{ audit_columns() }}

    FROM orders_raw o
    LEFT JOIN order_item_agg oia ON oia.order_id = o.order_id

)

SELECT * FROM enriched
