{% macro generate_schema_name(custom_schema_name, node) -%}
    {#
        Override the default dbt behaviour of prepending target.schema to custom schemas.
        By default dbt creates schemas like: <target_schema>_<custom_schema>
        e.g. DBT_DEV_JSMITH_CUSTOMERS

        This macro instead uses:
          - In PROD: just the custom_schema_name (e.g. CUSTOMERS)
          - In DEV/CI: <dev_prefix>_<custom_schema_name> (e.g. DEV_JSMITH_CUSTOMERS)

        This ensures production models land in the correct schemas while developers
        work in isolated namespaces that mirror the prod schema names.
    #}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}

    {%- elif target.name == 'prod' -%}
        {# Production: use the schema exactly as defined in dbt_project.yml #}
        {{ custom_schema_name | trim | upper }}

    {%- else -%}
        {# Non-prod: prefix with the developer's target schema for isolation #}
        {{ default_schema }}_{{ custom_schema_name | trim | upper }}

    {%- endif -%}

{%- endmacro %}
