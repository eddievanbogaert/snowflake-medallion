{% test not_null_proportion(model, column_name, min_proportion=0.95) %}
    {#
        Custom generic test: asserts that at least min_proportion of rows
        have a non-null value for column_name.
        Useful for columns that allow NULLs but shouldn't have too many.

        Usage in schema.yml:
            columns:
              - name: email_address
                data_tests:
                  - not_null_proportion:
                      min_proportion: 0.90
    #}
    WITH stats AS (
        SELECT
            COUNT(*)                                                        AS total_rows,
            SUM(CASE WHEN {{ column_name }} IS NOT NULL THEN 1 ELSE 0 END)  AS non_null_rows
        FROM {{ model }}
    )
    SELECT
        total_rows,
        non_null_rows,
        ROUND(non_null_rows * 1.0 / NULLIF(total_rows, 0), 4)  AS actual_proportion,
        {{ min_proportion }}                                   AS min_required_proportion
    FROM stats
    WHERE non_null_rows * 1.0 / NULLIF(total_rows, 0) < {{ min_proportion }}
{% endtest %}


{% test row_count_between(model, min_rows=1, max_rows=none) %}
    {#
        Custom generic test: asserts the model has at least min_rows rows,
        and optionally no more than max_rows.
        Useful for catching empty loads or data explosions.

        Usage in schema.yml (model-level):
            data_tests:
              - row_count_between:
                  min_rows: 1000
                  max_rows: 100000000
    #}
    WITH stats AS (
        SELECT COUNT(*) AS row_count
        FROM {{ model }}
    )
    SELECT row_count
    FROM stats
    WHERE row_count < {{ min_rows }}
    {% if max_rows is not none %}
       OR row_count > {{ max_rows }}
    {% endif %}
{% endtest %}


{% test no_duplicate_pk(model, column_name) %}
    {#
        Custom generic test: returns rows that represent duplicate primary keys.
        Equivalent to the built-in `unique` test, but reports the duplicate
        count per key, which is more useful when triaging bad loads.
    #}
    SELECT
        {{ column_name }},
        COUNT(*) AS occurrence_count
    FROM {{ model }}
    GROUP BY {{ column_name }}
    HAVING COUNT(*) > 1
{% endtest %}


{% macro get_column_stats(relation, column_name) %}
    {#
        Utility macro: returns basic stats for a column.
        Used in analyses and debugging, not tests.
    #}
    SELECT
        '{{ column_name }}'                     AS column_name,
        COUNT(*)                                AS total_rows,
        COUNT({{ column_name }})                AS non_null_rows,
        COUNT(*) - COUNT({{ column_name }})     AS null_rows,
        COUNT(DISTINCT {{ column_name }})       AS distinct_values,
        MIN({{ column_name }})::VARCHAR         AS min_value,
        MAX({{ column_name }})::VARCHAR         AS max_value
    FROM {{ relation }}
{% endmacro %}


{% macro log_test_results(results) %}
    {#
        on-run-end hook: persists every test result of the invocation to
        MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS, which feeds the
        ALERT_DBT_TEST_FAILURES Snowflake alert (monitoring/03_alerts.sql).

        Wired in dbt_project.yml:
          on-run-end:
            - "{{ log_test_results(results) }}"

        Prod-only: the results table lives in MONITORING_DB, which only the
        prod TRANSFORMER_ROLE can write to. Dev/CI runs skip logging.
    #}
    {% if execute and target.name == 'prod' %}
        {% set test_results = results | selectattr('node.resource_type', 'equalto', 'test') | list %}
        {% if test_results | length > 0 %}
            {% set value_rows = [] %}
            {% for res in test_results %}
                {% set model_name = (res.node.attached_node or '').split('.')[-1] %}
                {% set message = (res.message or '') | replace("'", "''") | truncate(1900, True) %}
                {% do value_rows.append(
                    "('"  ~ invocation_id ~ "'"
                    ~ ",'" ~ res.node.unique_id ~ "'"
                    ~ ",'" ~ res.node.name ~ "'"
                    ~ ",'" ~ model_name ~ "'"
                    ~ ",'" ~ res.status ~ "'"
                    ~ ","  ~ (res.failures if res.failures is not none else 0)
                    ~ ",'" ~ message ~ "')"
                ) %}
            {% endfor %}
            {% do run_query(
                "INSERT INTO MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS "
                ~ "(run_id, node_id, test_name, model_name, status, failures, message) VALUES "
                ~ value_rows | join(', ')
            ) %}
            {{ log("Logged " ~ value_rows | length ~ " test results to MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS", info=True) }}
        {% endif %}
    {% endif %}
{% endmacro %}
