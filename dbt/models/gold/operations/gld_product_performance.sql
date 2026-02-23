{{
    config(
        materialized = 'table',
        tags         = ['gold', 'operations'],
        meta         = {
            'owner': 'data-products',
            'description': 'Product performance scorecard for Operations and Supply Chain.',
            'row_access_policy': 'DOMAIN_ACCESS_POLICY'
        }
    )
}}

/*
    Gold layer: gld_product_performance
    ======================================
    Product-level performance metrics for Operations and Supply Chain planning.
    Grain: one row per product.

    Metrics:
      - Sales velocity (units per day rolling 30/90 days)
      - Revenue and margin contribution
      - Return rate and cancellation rate
      - Fulfilment speed (avg days to ship)
*/

WITH products AS (

    SELECT * FROM {{ ref('slv_products') }}
    WHERE is_active = TRUE

),

order_items AS (

    SELECT * FROM {{ ref('slv_order_items') }}

),

orders AS (

    SELECT
        order_id,
        order_date,
        shipped_date,
        days_to_ship,
        order_status
    FROM {{ ref('slv_orders') }}

),

product_order_detail AS (

    SELECT
        oi.product_id,
        oi.order_id,
        oi.quantity,
        oi.unit_price,
        oi.line_total,
        oi.discount_pct,
        o.order_date::DATE                  AS order_date,
        o.order_status,
        o.days_to_ship

    FROM order_items oi
    INNER JOIN orders o ON o.order_id = oi.order_id

),

metrics AS (

    SELECT
        product_id,

        -- Overall sales history
        COUNT(DISTINCT order_id)                                    AS total_orders,
        SUM(CASE WHEN order_status = 'DELIVERED' THEN quantity ELSE 0 END) AS units_delivered,
        SUM(CASE WHEN order_status = 'CANCELLED' THEN quantity ELSE 0 END) AS units_cancelled,
        SUM(CASE WHEN order_status = 'RETURNED'  THEN quantity ELSE 0 END) AS units_returned,
        SUM(CASE WHEN order_status = 'DELIVERED' THEN line_total ELSE 0 END) AS total_revenue,
        MIN(order_date)                                             AS first_sale_date,
        MAX(order_date)                                             AS last_sale_date,

        -- Rolling 30-day
        SUM(CASE WHEN order_date >= DATEADD('day', -30, CURRENT_DATE())
                      AND order_status = 'DELIVERED'
                 THEN quantity ELSE 0 END)                          AS units_l30d,
        SUM(CASE WHEN order_date >= DATEADD('day', -30, CURRENT_DATE())
                      AND order_status = 'DELIVERED'
                 THEN line_total ELSE 0 END)                        AS revenue_l30d,

        -- Rolling 90-day
        SUM(CASE WHEN order_date >= DATEADD('day', -90, CURRENT_DATE())
                      AND order_status = 'DELIVERED'
                 THEN quantity ELSE 0 END)                          AS units_l90d,
        SUM(CASE WHEN order_date >= DATEADD('day', -90, CURRENT_DATE())
                      AND order_status = 'DELIVERED'
                 THEN line_total ELSE 0 END)                        AS revenue_l90d,

        -- Fulfilment
        AVG(CASE WHEN order_status = 'DELIVERED' THEN days_to_ship END) AS avg_days_to_ship,
        MAX(CASE WHEN order_status = 'DELIVERED' THEN days_to_ship END) AS max_days_to_ship

    FROM product_order_detail
    GROUP BY product_id

),

final AS (

    SELECT
        p.product_id,
        p.sku,
        p.product_name,
        p.category_name                                             AS product_category,
        p.brand_name,
        p.unit_cost,
        p.list_price,
        p.weight_kg,

        -- Sales velocity
        COALESCE(m.total_orders, 0)                                AS total_orders,
        COALESCE(m.units_delivered, 0)                             AS units_delivered,
        COALESCE(m.units_cancelled, 0)                             AS units_cancelled,
        COALESCE(m.units_returned, 0)                              AS units_returned,
        COALESCE(m.total_revenue, 0)                               AS total_revenue,

        -- Rates
        ROUND(
            COALESCE(m.units_returned, 0) * 100.0
            / NULLIF(m.units_delivered, 0), 2
        )                                                          AS return_rate_pct,

        ROUND(
            COALESCE(m.units_cancelled, 0) * 100.0
            / NULLIF(m.total_orders, 0), 2
        )                                                          AS cancellation_rate_pct,

        -- Margin
        ROUND(
            (p.list_price - p.unit_cost) / NULLIF(p.list_price, 0) * 100,
            2
        )                                                          AS list_margin_pct,

        ROUND(
            COALESCE(m.total_revenue, 0)
            - (COALESCE(m.units_delivered, 0) * p.unit_cost),
            2
        )                                                          AS total_gross_margin,

        -- Rolling windows
        COALESCE(m.units_l30d, 0)                                  AS units_l30d,
        COALESCE(m.revenue_l30d, 0)                                AS revenue_l30d,
        ROUND(COALESCE(m.units_l30d, 0) / 30.0, 2)                AS daily_velocity_l30d,
        COALESCE(m.units_l90d, 0)                                  AS units_l90d,
        COALESCE(m.revenue_l90d, 0)                                AS revenue_l90d,

        -- Dates
        m.first_sale_date,
        m.last_sale_date,
        DATEDIFF('day', m.last_sale_date, CURRENT_DATE())          AS days_since_last_sale,

        -- Fulfilment
        ROUND(m.avg_days_to_ship, 1)                               AS avg_days_to_ship,
        m.max_days_to_ship,

        -- RLS anchor
        'OPERATIONS'                                               AS data_domain,

        {{ audit_columns() }}

    FROM products p
    LEFT JOIN metrics m ON m.product_id = p.product_id

)

SELECT * FROM final
