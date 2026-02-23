/*
    Singular test: test_gold_revenue_no_negative
    ==============================================
    Asserts that no row in gld_revenue_summary has a negative gross_revenue
    or net_revenue. Negative values indicate a data pipeline error, not
    valid returns (returns are modelled separately in order_status).

    This test will FAIL the CI pipeline if any row violates the constraint.
*/

SELECT
    order_date,
    product_category,
    country_code,
    gross_revenue,
    net_revenue
FROM {{ ref('gld_revenue_summary') }}
WHERE gross_revenue < 0
   OR net_revenue < 0
