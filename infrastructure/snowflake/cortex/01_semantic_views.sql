-- =============================================================================
-- cortex/01_semantic_views.sql
-- Semantic views over the gold layer — the governed semantic model that
-- Cortex Analyst / Snowflake Intelligence use to answer natural-language
-- questions with correct, consistent SQL.
--
-- WHY SEMANTIC VIEWS
-- ------------------
-- A semantic view declares the business meaning of a table once — dimensions,
-- metrics, synonyms — so every NL question ("what was net revenue by channel
-- last month?") compiles to the SAME governed logic instead of an LLM's guess.
-- They are schema-level objects, RBAC-governed like any view, and the row
-- access policies on the underlying gold tables still apply to the querying
-- user.
--
-- CONSUMPTION
-- -----------
--   • Cortex Analyst REST API / Snowflake Intelligence — point them at these
--     semantic views per domain.
--   • Direct SQL:  SELECT * FROM SEMANTIC_VIEW(
--                      ANALYTICS_DB.FINANCE.SV_REVENUE
--                      METRICS total_net_revenue
--                      DIMENSIONS order_month, product_category);
--
-- Reference: https://docs.snowflake.com/en/user-guide/views-semantic/overview
--
-- Run as: SYSADMIN (inherits read on gold via role hierarchy)
-- Prerequisites: dbt has built the gold tables; 00_cortex_governance.sql.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
GRANT CREATE SEMANTIC VIEW ON SCHEMA ANALYTICS_DB.FINANCE   TO ROLE SYSADMIN;
GRANT CREATE SEMANTIC VIEW ON SCHEMA ANALYTICS_DB.MARKETING TO ROLE SYSADMIN;

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- FINANCE: revenue semantic model over GLD_REVENUE_SUMMARY
-- ---------------------------------------------------------------------------

CREATE OR REPLACE SEMANTIC VIEW ANALYTICS_DB.FINANCE.SV_REVENUE
    TABLES (
        revenue AS ANALYTICS_DB.FINANCE.GLD_REVENUE_SUMMARY
            PRIMARY KEY (order_date, product_category, country_code,
                         acquisition_channel, currency_code, payment_method)
            WITH SYNONYMS ('revenue summary', 'daily revenue', 'sales')
            COMMENT = 'Daily revenue roll-up by category, country, channel, currency, and payment method.'
    )
    DIMENSIONS (
        revenue.order_date            AS order_date
            WITH SYNONYMS ('date', 'day')            COMMENT = 'Order date (daily grain).',
        revenue.order_month           AS order_month
            WITH SYNONYMS ('month')                  COMMENT = 'First day of the order month.',
        revenue.product_category      AS product_category
            WITH SYNONYMS ('category')               COMMENT = 'Product category name.',
        revenue.country_code          AS country_code
            WITH SYNONYMS ('country')                COMMENT = 'Customer ISO 3166-1 alpha-2 country code.',
        revenue.acquisition_channel   AS acquisition_channel
            WITH SYNONYMS ('channel')                COMMENT = 'Customer acquisition channel.',
        revenue.currency_code         AS currency_code
            WITH SYNONYMS ('currency')               COMMENT = 'ISO 4217 currency of the order.',
        revenue.payment_method        AS payment_method                                COMMENT = 'Payment method used.'
    )
    METRICS (
        revenue.total_gross_revenue   AS SUM(gross_revenue)
            WITH SYNONYMS ('gross revenue', 'gross sales')
            COMMENT = 'Pre-discount revenue (quantity x unit price).',
        revenue.total_net_revenue     AS SUM(net_revenue)
            WITH SYNONYMS ('net revenue', 'revenue', 'sales')
            COMMENT = 'Revenue after line discounts.',
        revenue.total_gross_margin    AS SUM(gross_margin)
            WITH SYNONYMS ('margin', 'gross margin')
            COMMENT = 'Net revenue minus cost of goods (NULL-cost products excluded).',
        revenue.total_orders          AS SUM(order_count)
            WITH SYNONYMS ('orders', 'order count')
            COMMENT = 'Count of distinct orders contributing to the row.',
        revenue.total_units           AS SUM(total_units_sold)
            WITH SYNONYMS ('units', 'units sold')
            COMMENT = 'Total units sold.'
    )
    COMMENT = 'Finance semantic model — governed metrics for Cortex Analyst / Snowflake Intelligence.';

-- ---------------------------------------------------------------------------
-- MARKETING: customer semantic model over GLD_CUSTOMER_360
-- (PII columns are deliberately NOT exposed as dimensions — Analyst answers
-- segmentation questions without surfacing emails/names/phones.)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE SEMANTIC VIEW ANALYTICS_DB.MARKETING.SV_CUSTOMER_360
    TABLES (
        customers AS ANALYTICS_DB.MARKETING.GLD_CUSTOMER_360
            PRIMARY KEY (customer_id)
            WITH SYNONYMS ('customer 360', 'customers')
            COMMENT = 'One row per customer: profile, lifetime value, engagement, RFM segment.'
    )
    DIMENSIONS (
        customers.rfm_segment          AS rfm_segment
            WITH SYNONYMS ('segment', 'customer segment')  COMMENT = 'RFM-derived segment (CHAMPION, AT_RISK, ...).',
        customers.age_band             AS age_band                                       COMMENT = 'Non-PII age grouping.',
        customers.country_code         AS country_code
            WITH SYNONYMS ('country')                      COMMENT = 'ISO 3166-1 alpha-2 country code.',
        customers.acquisition_channel  AS acquisition_channel
            WITH SYNONYMS ('channel')                      COMMENT = 'Acquisition channel.',
        customers.customer_status      AS customer_status
            WITH SYNONYMS ('status')                       COMMENT = 'Account status.',
        customers.tenure_band          AS tenure_band                                    COMMENT = 'Customer tenure grouping.'
    )
    METRICS (
        customers.customer_count       AS COUNT(customer_id)
            WITH SYNONYMS ('customers', 'number of customers')
            COMMENT = 'Count of customers.',
        customers.total_lifetime_revenue AS SUM(lifetime_revenue)
            WITH SYNONYMS ('lifetime value', 'ltv', 'clv')
            COMMENT = 'Sum of delivered order revenue across customers.',
        customers.avg_lifetime_revenue AS AVG(lifetime_revenue)
            WITH SYNONYMS ('average ltv')
            COMMENT = 'Average lifetime revenue per customer.',
        customers.total_delivered_orders AS SUM(delivered_orders)
            WITH SYNONYMS ('delivered orders')
            COMMENT = 'Total delivered orders.'
    )
    COMMENT = 'Marketing semantic model — segmentation and LTV questions without exposing PII columns.';

-- ---------------------------------------------------------------------------
-- ACCESS: who may query the semantic models
-- (Row access policies on the underlying tables still filter per user.)
-- ---------------------------------------------------------------------------

GRANT SELECT ON SEMANTIC VIEW ANALYTICS_DB.FINANCE.SV_REVENUE        TO ROLE DATA_ANALYST_ROLE;
GRANT SELECT ON SEMANTIC VIEW ANALYTICS_DB.FINANCE.SV_REVENUE        TO ROLE POWERBI_FINANCE_ROLE;
GRANT SELECT ON SEMANTIC VIEW ANALYTICS_DB.MARKETING.SV_CUSTOMER_360 TO ROLE DATA_ANALYST_ROLE;
GRANT SELECT ON SEMANTIC VIEW ANALYTICS_DB.MARKETING.SV_CUSTOMER_360 TO ROLE POWERBI_MARKETING_ROLE;

-- ---------------------------------------------------------------------------
-- SMOKE TEST
-- ---------------------------------------------------------------------------
-- SELECT * FROM SEMANTIC_VIEW(
--     ANALYTICS_DB.FINANCE.SV_REVENUE
--     METRICS total_net_revenue, total_orders
--     DIMENSIONS order_month, acquisition_channel
-- ) ORDER BY order_month DESC;
--
-- NOTE: after a dbt full refresh recreates a gold table, semantic views over
-- it remain valid (they bind by name), but re-run this script whenever the
-- gold schema changes shape.
