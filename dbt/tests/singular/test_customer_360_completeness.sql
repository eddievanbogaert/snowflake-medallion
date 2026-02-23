/*
    Singular test: test_customer_360_completeness
    ================================================
    Asserts that all active customers in slv_customers appear in
    gld_customer_360. Missing customers indicate a broken join or filter
    in the gold model.

    Returns rows (failure) only if any active customer is absent.
*/

SELECT
    c.customer_id,
    c.customer_status,
    c.created_at
FROM {{ ref('slv_customers') }} c
LEFT JOIN {{ ref('gld_customer_360') }} g
    ON g.customer_id = c.customer_id
WHERE c.customer_status IN ('ACTIVE', 'PROSPECT', 'DEVELOPING')
  AND g.customer_id IS NULL
