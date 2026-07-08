{{
    config(
        materialized = 'view',
        tags         = ['bronze', 'sqlserver', 'orders']
    )
}}

/*
    Bronze layer: brz_sqlserver_orders
    ====================================
    Non-transforming view over the Fivetran-managed raw orders table.
*/

SELECT
    order_id,
    customer_id,
    order_date,
    required_date,
    shipped_date,
    order_status,
    order_total,
    discount_amount,
    tax_amount,
    currency_code,
    shipping_address_id,
    billing_address_id,
    payment_method,
    notes,
    created_at,
    updated_at,
    _fivetran_synced,
    _fivetran_deleted,
    _fivetran_id
FROM {{ source('sqlserver_raw', 'orders') }}
WHERE (_fivetran_deleted IS NULL OR _fivetran_deleted = FALSE)
