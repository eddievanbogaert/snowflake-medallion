{% macro not_null_proportion(column_name, min_proportion=0.95) %}
    {#
        Custom generic test: asserts that at least min_proportion of rows
        have a non-null value for column_name.
        Useful for columns that allow NULLs but shouldn't have too many.

        Usage in schema.yml:
            columns:
              - name: email_address
                tests:
                  - not_null_proportion:
                      min_proportion: 0.90
    #}
    SELECT
        COUNT(*) AS total_rows,
        SUM(CASE WHEN {{ column_name }} IS NOT NULL THEN 1 ELSE 0 END) AS non_null_rows,
        ROUND(
            SUM(CASE WHEN {{ column_name }} IS NOT NULL THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*), 0),
            4
        ) AS actual_proportion,
        {{ min_proportion }} AS min_required_proportion
    FROM {{ model }}
    HAVING actual_proportion < min_required_proportion
{% endmacro %}


{% macro assert_row_count_between(min_rows, max_rows=none) %}
    {#
        Custom singular test: asserts the model has at least min_rows rows,
        and optionally no more than max_rows.
        Useful for catching empty loads or data explosions.
    #}
    SELECT COUNT(*) AS row_count
    FROM {{ model }}
    HAVING row_count < {{ min_rows }}
    {% if max_rows %}
        OR row_count > {{ max_rows }}
    {% endif %}
{% endmacro %}


{% macro test_no_duplicate_pk(model, pk_column) %}
    {#
        Returns rows that represent duplicate primary keys.
        Used as a singular test.
    #}
    SELECT
        {{ pk_column }},
        COUNT(*) AS occurrence_count
    FROM {{ model }}
    GROUP BY {{ pk_column }}
    HAVING COUNT(*) > 1
{% endmacro %}


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


{% macro log_dbt_test_result(test_name, model_name, status, failures, message) %}
    {#
        Called from an on-run-end hook to persist test results to MONITORING_DB.
        Example hook in dbt_project.yml:
          on-run-end:
            - "{{ log_dbt_test_result(...) }}"
        In practice, use an on-run-end macro that iterates over results.
    #}
    INSERT INTO MONITORING_DB.DATA_QUALITY.DBT_TEST_RESULTS
        (run_id, node_id, test_name, model_name, status, failures, message)
    VALUES (
        '{{ invocation_id }}',
        '{{ test_name }}',
        '{{ test_name }}',
        '{{ model_name }}',
        '{{ status }}',
        {{ failures | default(0) }},
        '{{ message | replace("'", "''") }}'
    );
{% endmacro %}
