{% macro audit_columns() %}
    {#
        Appends standard audit columns to every model's SELECT list.
        Usage: add {{ audit_columns() }} at the end of every model's SELECT.

        Columns added:
            _dbt_run_id     — unique identifier for this dbt invocation (for debugging)
            _dbt_model      — the fully-qualified dbt model name
            _loaded_at      — UTC timestamp when this row was written by dbt
            _batch_date     — the DATE portion of _loaded_at (for partition filtering)
    #}
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS _loaded_at,
    CURRENT_DATE()                     AS _batch_date,
    '{{ invocation_id }}'              AS _dbt_run_id,
    '{{ this.identifier }}'            AS _dbt_model
{% endmacro %}


{% macro incremental_date_filter(timestamp_column, lookback_days=none) %}
    {#
        Standard incremental filter for merge strategy.
        Uses var('incremental_lookback_days') with an optional per-call override.
        The lookback window prevents missing rows due to late-arriving data.

        Usage in a model:
            {% if is_incremental() %}
            WHERE {{ incremental_date_filter('updated_at') }}
            {% endif %}
    #}
    {% set days = lookback_days or var('incremental_lookback_days', 3) %}
    {{ timestamp_column }} >= DATEADD('day', -{{ days }}, CURRENT_TIMESTAMP())
{% endmacro %}


{% macro source_freshness_assertion(source_name, table_name, timestamp_column, max_hours) %}
    {#
        Inline assertion that source data is fresh enough before running a model.
        Raises an error if the most recent record in the source is older than max_hours.

        Usage:
            {{ source_freshness_assertion('sqlserver_raw', 'brz_sqlserver_customers', 'updated_at', 26) }}
    #}
    {% if execute %}
        {% set freshness_query %}
            SELECT DATEDIFF('hour', MAX({{ timestamp_column }}), CURRENT_TIMESTAMP()) AS lag_hours
            FROM {{ source(source_name, table_name) }}
        {% endset %}

        {% set result = run_query(freshness_query) %}
        {% if result and result.rows %}
            {% set lag = result.rows[0][0] %}
            {% if lag is not none and lag > max_hours %}
                {{ exceptions.raise_compiler_error(
                    "Source freshness check failed: " ~ source_name ~ "." ~ table_name
                    ~ " is " ~ lag ~ " hours old (max allowed: " ~ max_hours ~ " hours)."
                ) }}
            {% endif %}
        {% endif %}
    {% endif %}
{% endmacro %}


{% macro empty_string_to_null(column_name) %}
    {#
        Converts empty strings to NULL — normalises source systems that use ''
        instead of NULL for missing values.
        Usage: {{ empty_string_to_null('email_address') }} AS email_address
    #}
    NULLIF(TRIM({{ column_name }}), '')
{% endmacro %}


{% macro safe_cast_date(column_name, fallback='NULL') %}
    {#
        Safe date casting that returns NULL (or a fallback) on invalid dates,
        rather than failing the entire model.
        Useful for bronze → silver casting of string date columns.
    #}
    TRY_TO_DATE({{ column_name }})
{% endmacro %}


{% macro safe_cast_timestamp(column_name) %}
    TRY_TO_TIMESTAMP_NTZ({{ column_name }})
{% endmacro %}


{% macro safe_cast_number(column_name) %}
    TRY_TO_NUMBER({{ column_name }}, 18, 4)
{% endmacro %}
