{{
    config(
        materialized = 'table',
        tags         = ['gold', 'finance'],
        meta         = {
            'owner': 'data-products',
            'description': 'Daily revenue summary for the Finance domain. Certified for P&L reporting.',
            'row_access_policy': {
                'policy': 'FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY',
                'on': ['DATA_DOMAIN']
            },
            'powerbi_certified': true
        }
    )
}}

/*
    Gold layer: gld_revenue_summary
    =================================
    Daily revenue roll-up by date, product category, country, and acquisition channel.
    Primary data product for Finance dashboards, P&L reporting, and budget variance.

    Grain: one row per (order_date, product_category, country_code, acquisition_channel).

    Row Access Policy: DOMAIN_ACCESS_POLICY applied post-creation on DATA_DOMAIN.
*/

WITH orders AS (

    SELECT * FROM {{ ref('slv_orders') }}
    WHERE order_status IN ('DELIVERED', 'SHIPPED')  -- Revenue recognised on delivery/shipment

),

order_items AS (

    SELECT * FROM {{ ref('slv_order_items') }}

),

products AS (

    SELECT * FROM {{ ref('slv_products') }}

),

customers AS (

    SELECT
        customer_id,
        country_code,
        acquisition_channel
    FROM {{ ref('slv_customers') }}

),

-- Join orders → items → products → customers for full context
enriched_orders AS (

    SELECT
        o.order_id,
        o.order_date::DATE                                              AS order_date,
        DATE_TRUNC('week',  o.order_date::DATE)                        AS order_week,
        DATE_TRUNC('month', o.order_date::DATE)                        AS order_month,
        DATE_TRUNC('year',  o.order_date::DATE)                        AS order_year,

        o.customer_id,
        c.country_code,
        c.acquisition_channel,
        o.currency_code,
        o.payment_method,
        o.order_status,

        oi.order_item_id,
        oi.product_id,
        p.category_name                                                 AS product_category,
        p.brand_name,

        oi.quantity,
        oi.unit_price,
        oi.line_total,
        oi.discount_pct,
        oi.gross_margin,
        o.tax_amount / NULLIF(o.line_item_count, 0)                    AS allocated_tax

    FROM orders o
    INNER JOIN order_items oi   ON oi.order_id    = o.order_id
    LEFT JOIN  products    p    ON p.product_id   = oi.product_id
    LEFT JOIN  customers   c    ON c.customer_id  = o.customer_id

),

daily_summary AS (

    SELECT
        order_date,
        order_week,
        order_month,
        order_year,

        -- Dimensions
        COALESCE(product_category, 'UNCATEGORISED')                    AS product_category,
        COALESCE(country_code, 'UNKNOWN')                              AS country_code,
        COALESCE(acquisition_channel, 'UNKNOWN')                       AS acquisition_channel,
        COALESCE(currency_code, 'USD')                                 AS currency_code,
        COALESCE(payment_method, 'UNKNOWN')                            AS payment_method,

        -- Volume
        COUNT(DISTINCT order_id)                                       AS order_count,
        COUNT(DISTINCT customer_id)                                    AS unique_customers,
        SUM(quantity)                                                  AS total_units_sold,

        -- Revenue. line_total arrives from silver ALREADY NET of line
        -- discounts (slv_order_items cross-checks this), so gross revenue is
        -- re-derived from quantity × unit_price. Applying the discount to
        -- line_total again would double-discount.
        SUM(quantity * unit_price)                                     AS gross_revenue,
        SUM(line_total)                                                AS net_revenue,
        SUM(gross_margin)                                              AS gross_margin,
        SUM(allocated_tax)                                             AS tax_collected,

        -- Averages
        AVG(line_total)                                                AS avg_order_line_value,
        SUM(line_total) / NULLIF(COUNT(DISTINCT order_id), 0)          AS avg_order_value,

        -- Margin rate
        ROUND(
            SUM(gross_margin) / NULLIF(SUM(line_total), 0) * 100,
            2
        )                                                              AS gross_margin_pct,

        -- Row-level security anchor
        'FINANCE'                                                      AS data_domain,

        -- Audit
        {{ audit_columns() }}

    FROM enriched_orders
    GROUP BY
        order_date, order_week, order_month, order_year,
        product_category, country_code, acquisition_channel,
        currency_code, payment_method

)

SELECT * FROM daily_summary
ORDER BY order_date DESC
