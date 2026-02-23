{{
    config(
        materialized = 'view',
        tags         = ['bronze', 'sqlserver', 'orders']
    )
}}

SELECT
    order_item_id,
    order_id,
    product_id,
    quantity,
    unit_price,
    discount_pct,
    line_total,
    created_at,
    updated_at,
    _fivetran_synced,
    _fivetran_deleted,
    _fivetran_id
FROM {{ source('sqlserver_raw', 'brz_sqlserver_order_items') }}
WHERE (_fivetran_deleted IS NULL OR _fivetran_deleted = FALSE)
