/*
    Singular test: test_silver_no_orphan_orders
    =============================================
    Asserts that fewer than 1% of orders in slv_orders have a customer_id
    that does not exist in slv_customers. A higher rate suggests a sync
    ordering issue between the customers and orders Fivetran connectors.

    Returns rows (failure) only if the orphan rate exceeds the 1% threshold.
    Using a proportional test rather than a strict zero check because a small
    number of orphans is acceptable during the replication window.
*/

WITH order_customer_check AS (

    SELECT
        o.order_id,
        o.customer_id,
        c.customer_id AS matched_customer_id
    FROM {{ ref('slv_orders') }} o
    LEFT JOIN {{ ref('slv_customers') }} c
        ON c.customer_id = o.customer_id

),

stats AS (

    SELECT
        COUNT(*)                                                AS total_orders,
        SUM(CASE WHEN matched_customer_id IS NULL THEN 1 ELSE 0 END) AS orphan_orders,
        ROUND(
            SUM(CASE WHEN matched_customer_id IS NULL THEN 1 ELSE 0 END) * 100.0
            / NULLIF(COUNT(*), 0),
            2
        )                                                       AS orphan_rate_pct

    FROM order_customer_check

)

-- Return a row (test fails) if orphan rate > 1%
SELECT *
FROM stats
WHERE orphan_rate_pct > 1.0
