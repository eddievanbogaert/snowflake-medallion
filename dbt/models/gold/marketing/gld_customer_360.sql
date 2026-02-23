{{
    config(
        materialized = 'table',
        tags         = ['gold', 'marketing'],
        meta         = {
            'owner': 'data-products',
            'description': 'Customer 360 view — primary data product for Marketing analytics and CRM.',
            'pii_present': true,
            'row_access_policy': 'DOMAIN_ACCESS_POLICY',
            'powerbi_certified': true
        }
    )
}}

/*
    Gold layer: gld_customer_360
    ==============================
    Primary data product for the Marketing domain.
    Provides a comprehensive, denormalised view of each customer including:
      - Profile and demographics (masked per role)
      - Lifecycle metrics (tenure, orders, revenue)
      - Engagement signals (last activity, event counts)
      - Segmentation attributes (RFM tiers, acquisition channel)

    Row Access Policy: DOMAIN_ACCESS_POLICY applied post-creation on DATA_DOMAIN column.
    Masking Policies: applied on PII columns (email_address, phone_number, full_name).

    Refresh: FULL TABLE, scheduled daily after silver models complete.
    Usage: Power BI Marketing dashboard, CRM export, marketing automation feed.
*/

WITH customers AS (

    SELECT * FROM {{ ref('slv_customers') }}
    WHERE customer_status NOT IN ('CLOSED')  -- Exclude fully closed accounts

),

-- Lifetime order metrics per customer
order_metrics AS (

    SELECT
        customer_id,
        COUNT(*)                                        AS total_orders,
        COUNT(CASE WHEN order_status = 'DELIVERED'
                   THEN 1 END)                          AS delivered_orders,
        COUNT(CASE WHEN order_status = 'CANCELLED'
                   THEN 1 END)                          AS cancelled_orders,
        COUNT(CASE WHEN order_status = 'RETURNED'
                   THEN 1 END)                          AS returned_orders,
        MIN(order_date)                                 AS first_order_date,
        MAX(order_date)                                 AS last_order_date,
        SUM(CASE WHEN order_status = 'DELIVERED'
                 THEN order_total ELSE 0 END)           AS lifetime_revenue,
        AVG(CASE WHEN order_status = 'DELIVERED'
                 THEN order_total END)                  AS avg_order_value,
        DATEDIFF('day',
            MAX(order_date),
            CURRENT_TIMESTAMP()
        )                                               AS days_since_last_order

    FROM {{ ref('slv_orders') }}
    GROUP BY customer_id

),

-- Recent engagement (last 90 days)
engagement_metrics AS (

    SELECT
        user_id                                         AS customer_id,
        COUNT(DISTINCT session_id)                      AS sessions_l90d,
        COUNT(*)                                        AS events_l90d,
        COUNT(DISTINCT event_date)                      AS active_days_l90d,
        COUNT(DISTINCT CASE WHEN event_type = 'product_viewed'
                            THEN event_id END)          AS product_views_l90d,
        COUNT(DISTINCT CASE WHEN event_type = 'add_to_cart'
                            THEN event_id END)          AS add_to_cart_l90d,
        MAX(event_timestamp)                            AS last_active_at

    FROM {{ ref('slv_events') }}
    WHERE event_date >= DATEADD('day', -90, CURRENT_DATE())
      AND user_id IS NOT NULL
    GROUP BY user_id

),

-- RFM scoring: Recency, Frequency, Monetary
-- Score each dimension 1-5, then combine to a segment label
rfm_scores AS (

    SELECT
        customer_id,
        -- Recency score: 5 = most recent
        NTILE(5) OVER (ORDER BY days_since_last_order ASC NULLS LAST)  AS recency_score,
        -- Frequency score: 5 = most orders
        NTILE(5) OVER (ORDER BY delivered_orders DESC NULLS LAST)      AS frequency_score,
        -- Monetary score: 5 = highest revenue
        NTILE(5) OVER (ORDER BY lifetime_revenue DESC NULLS LAST)      AS monetary_score
    FROM order_metrics

),

rfm_segments AS (

    SELECT
        customer_id,
        recency_score,
        frequency_score,
        monetary_score,
        (recency_score + frequency_score + monetary_score) / 3.0       AS rfm_avg_score,
        CASE
            WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4
                THEN 'CHAMPION'
            WHEN recency_score >= 4 AND frequency_score >= 3
                THEN 'LOYAL_CUSTOMER'
            WHEN recency_score >= 4 AND frequency_score <= 2
                THEN 'POTENTIAL_LOYALIST'
            WHEN recency_score = 5 AND frequency_score = 1
                THEN 'NEW_CUSTOMER'
            WHEN recency_score <= 2 AND frequency_score >= 3 AND monetary_score >= 3
                THEN 'AT_RISK'
            WHEN recency_score = 1 AND frequency_score >= 4 AND monetary_score >= 4
                THEN 'CANNOT_LOSE'
            WHEN recency_score <= 2 AND frequency_score <= 2
                THEN 'HIBERNATING'
            WHEN recency_score >= 3 AND frequency_score <= 2 AND monetary_score <= 2
                THEN 'PROMISING'
            ELSE 'NEEDS_ATTENTION'
        END                                                             AS rfm_segment
    FROM rfm_scores

),

final AS (

    SELECT
        -- Identity (PII — masking policies applied post-creation)
        c.customer_id,
        c.full_name,
        c.email_address,
        c.phone_number,

        -- Demographics (non-PII)
        c.age_band,
        c.gender,
        c.country_code,
        c.city,
        c.state_province,

        -- Acquisition
        c.acquisition_channel,
        c.customer_status,
        c.created_at                                                    AS customer_since,

        -- Tenure
        DATEDIFF('day', c.created_at, CURRENT_TIMESTAMP())             AS tenure_days,
        CASE
            WHEN DATEDIFF('day', c.created_at, CURRENT_TIMESTAMP()) < 90  THEN 'NEW'
            WHEN DATEDIFF('day', c.created_at, CURRENT_TIMESTAMP()) < 365 THEN 'DEVELOPING'
            WHEN DATEDIFF('day', c.created_at, CURRENT_TIMESTAMP()) < 730 THEN 'ESTABLISHED'
            ELSE 'VETERAN'
        END                                                             AS tenure_band,

        -- Order metrics
        COALESCE(om.total_orders, 0)                                   AS total_orders,
        COALESCE(om.delivered_orders, 0)                               AS delivered_orders,
        COALESCE(om.cancelled_orders, 0)                               AS cancelled_orders,
        COALESCE(om.returned_orders, 0)                                AS returned_orders,
        om.first_order_date,
        om.last_order_date,
        COALESCE(om.lifetime_revenue, 0)                               AS lifetime_revenue,
        om.avg_order_value,
        om.days_since_last_order,

        -- Engagement
        COALESCE(em.sessions_l90d, 0)                                  AS sessions_l90d,
        COALESCE(em.events_l90d, 0)                                    AS events_l90d,
        COALESCE(em.active_days_l90d, 0)                               AS active_days_l90d,
        COALESCE(em.product_views_l90d, 0)                             AS product_views_l90d,
        COALESCE(em.add_to_cart_l90d, 0)                               AS add_to_cart_l90d,
        em.last_active_at,

        -- RFM Segmentation
        COALESCE(rfm.rfm_segment, 'NO_ORDERS')                        AS rfm_segment,
        rfm.recency_score,
        rfm.frequency_score,
        rfm.monetary_score,
        rfm.rfm_avg_score,

        -- Row-level security anchor column
        -- DOMAIN_ACCESS_POLICY filters on this column
        'MARKETING'                                                     AS data_domain,

        -- Audit
        {{ audit_columns() }}

    FROM customers c
    LEFT JOIN order_metrics  om  ON om.customer_id  = c.customer_id
    LEFT JOIN engagement_metrics em ON em.customer_id = c.customer_id::VARCHAR
    LEFT JOIN rfm_segments rfm ON rfm.customer_id = c.customer_id

)

SELECT * FROM final
