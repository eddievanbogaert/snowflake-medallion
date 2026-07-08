{% snapshot snp_customers %}
{{
    config(
        target_schema    = 'SNAPSHOTS',
        target_database  = ('FOUNDATION_DB' if target.name == 'prod' else target.database),
        strategy         = 'timestamp',
        unique_key       = 'customer_id',
        updated_at       = 'source_synced_at',
        invalidate_hard_deletes = True,
        tags             = ['snapshot', 'customers']
    )
}}

/*
    Snapshot: snp_customers (SCD Type 2)
    ======================================
    Tracks the full history of customer record changes using Slowly Changing
    Dimension Type 2 (SCD2) semantics.

    dbt adds the following columns automatically:
      dbt_scd_id        — unique identifier for each version record
      dbt_updated_at    — when this version was created in the snapshot
      dbt_valid_from    — timestamp when this version became active
      dbt_valid_to      — timestamp when this version was superseded (NULL = current)

    Usage examples:
      -- Get the current state of all customers
      SELECT * FROM FOUNDATION_DB.SNAPSHOTS.SNP_CUSTOMERS
      WHERE dbt_valid_to IS NULL;

      -- Get customer state as of a specific date (point-in-time lookup)
      SELECT * FROM FOUNDATION_DB.SNAPSHOTS.SNP_CUSTOMERS
      WHERE customer_id = 12345
        AND dbt_valid_from <= '2024-06-01'::TIMESTAMP
        AND (dbt_valid_to > '2024-06-01'::TIMESTAMP OR dbt_valid_to IS NULL);

      -- Identify customers who changed email in the last 30 days
      SELECT
          curr.customer_id,
          prev.email_address AS old_email,
          curr.email_address AS new_email,
          curr.dbt_valid_from AS changed_at
      FROM FOUNDATION_DB.SNAPSHOTS.SNP_CUSTOMERS curr
      INNER JOIN FOUNDATION_DB.SNAPSHOTS.SNP_CUSTOMERS prev
          ON curr.customer_id = prev.customer_id
         AND prev.dbt_valid_to = curr.dbt_valid_from
      WHERE curr.email_address <> prev.email_address
        AND curr.dbt_valid_from >= DATEADD('day', -30, CURRENT_TIMESTAMP());
*/

SELECT
    customer_id,
    first_name,
    last_name,
    full_name,
    email_address,
    phone_number,
    date_of_birth,
    age_band,
    gender,
    address_line_1,
    address_line_2,
    city,
    state_province,
    postal_code,
    country_code,
    customer_status,
    acquisition_channel,
    created_at,
    updated_at,
    source_synced_at,
    _dq_invalid_email,
    _dq_future_dob

FROM {{ ref('slv_customers') }}

{% endsnapshot %}
