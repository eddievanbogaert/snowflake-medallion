{{
    config(
        enabled             = var('enable_ai_enrichment', false),
        materialized        = 'incremental',
        unique_key          = 'product_id',
        incremental_strategy = 'merge',
        tags                = ['gold', 'ai'],
        meta                = {
            'owner': 'data-products',
            'description': 'AISQL enrichment: LLM-classified categories for products missing one.'
        }
    )
}}

/*
    Gold layer: gld_product_enrichment  (OPT-IN — disabled by default)
    ====================================================================
    Demonstrates governed AISQL usage inside dbt: AI_CLASSIFY assigns a
    category to active products whose source category is missing, so the
    revenue summary stops bucketing them as UNCATEGORISED.

    ENABLING
    --------
      1. Grant Cortex to the dbt role (see cortex/00_cortex_governance.sql):
         GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE TRANSFORMER_ROLE;
      2. Run with:  dbt run --select gld_product_enrichment --vars '{enable_ai_enrichment: true}'
         (or set enable_ai_enrichment: true in dbt_project.yml vars)

    COST CONTROLS
    -------------
      • Incremental: each product is classified ONCE, then remembered.
      • Per-run cap (ai_enrichment_batch_size, default 500 rows) bounds spend.
      • Account-level guardrails: model allowlist + AI_SERVICES budget alert
        (cortex/00_cortex_governance.sql).

    Review AI-assigned categories before feeding them into certified metrics —
    the ai_confidence-style review loop belongs in a human workflow, not here.
*/

WITH uncategorised AS (

    SELECT
        product_id,
        product_name,
        product_description
    FROM {{ ref('slv_products') }}
    WHERE category_name IS NULL
      AND is_active = TRUE
      AND product_name IS NOT NULL

    {% if is_incremental() %}
      -- classify each product at most once
      AND product_id NOT IN (SELECT product_id FROM {{ this }})
    {% endif %}

    LIMIT {{ var('ai_enrichment_batch_size', 500) }}

),

classified AS (

    SELECT
        product_id,
        product_name,
        AI_CLASSIFY(
            product_name || ' — ' || COALESCE(product_description, ''),
            [
                'Electronics', 'Apparel', 'Home and Garden', 'Sports and Outdoors',
                'Beauty and Personal Care', 'Toys and Games', 'Grocery',
                'Automotive', 'Office Supplies', 'Other'
            ]
        ) AS ai_result

    FROM uncategorised

)

SELECT
    product_id,
    product_name,
    ai_result:labels[0]::VARCHAR       AS ai_category,
    ai_result                          AS ai_raw_response,
    'AI_CLASSIFY'                      AS enrichment_method,

    {{ audit_columns() }}

FROM classified
