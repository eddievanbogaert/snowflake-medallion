{{
    config(
        materialized = 'view',
        tags         = ['bronze', 'sqlserver', 'products']
    )
}}

SELECT
    product_id,
    sku,
    product_name,
    product_description,
    category_id,
    category_name,
    brand_id,
    brand_name,
    unit_cost,
    list_price,
    weight_kg,
    is_active,
    created_at,
    updated_at,
    _fivetran_synced,
    _fivetran_deleted,
    _fivetran_id
FROM {{ source('sqlserver_raw', 'products') }}
WHERE (_fivetran_deleted IS NULL OR _fivetran_deleted = FALSE)
