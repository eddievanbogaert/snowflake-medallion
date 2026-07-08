{% macro apply_security_policies() %}
    {#
        Post-hook: re-attach row access and masking policies after a model is
        (re)built.

        WHY THIS EXISTS
        ----------------
        CREATE OR REPLACE TABLE (how dbt rebuilds table/incremental full-refresh
        models) silently DROPS any row access policies, masking policies, and
        tags attached to the previous table. Without this hook, every dbt run
        would leave the gold tables readable by BI roles with NO masking and NO
        row filtering until someone manually re-ran
        powerbi/row_level_security/rls_snowflake_setup.sql.

        CONFIGURATION
        -------------
        Row access policy — model-level meta (in the model's config() block or
        schema.yml):
            meta:
              row_access_policy:
                policy: FOUNDATION_DB.ROW_POLICIES.DOMAIN_ACCESS_POLICY
                on: [DATA_DOMAIN]

        Masking policies — column-level meta in schema.yml:
            columns:
              - name: email_address
                meta:
                  masking_policy: FOUNDATION_DB.MASKING.EMAIL_MASK

        PRIVILEGES
        ----------
        TRANSFORMER_ROLE needs APPLY on each policy plus the account-level
        APPLY MASKING POLICY / APPLY ROW ACCESS POLICY privileges — granted in
        infrastructure/snowflake/security/03_column_masking_policies.sql and
        04_row_access_policies.sql.

        SCOPE
        -----
        Runs only for the prod target: the policy objects live in the
        production databases, and only TRANSFORMER_ROLE holds the APPLY
        privileges. Dev/CI builds are unaffected.
    #}
    {% if execute
          and target.name == 'prod'
          and model.config.materialized in ('table', 'incremental') %}

        {% set model_meta = model.config.get('meta') or model.get('meta') or {} %}

        {# ------ Row access policy ------ #}
        {% set rap = model_meta.get('row_access_policy') %}
        {% if rap is mapping and rap.get('policy') and rap.get('on') %}
            {% do run_query("ALTER TABLE " ~ this ~ " DROP ALL ROW ACCESS POLICIES") %}
            {% do run_query(
                "ALTER TABLE " ~ this
                ~ " ADD ROW ACCESS POLICY " ~ rap['policy']
                ~ " ON (" ~ rap['on'] | join(', ') ~ ")"
            ) %}
            {{ log("Applied row access policy " ~ rap['policy'] ~ " to " ~ this, info=False) }}
        {% elif rap is not none and rap is not mapping %}
            {{ exceptions.warn(
                "Model " ~ model.name ~ " has meta.row_access_policy in an unsupported format. "
                ~ "Expected a mapping with 'policy' and 'on' keys; policy NOT applied."
            ) }}
        {% endif %}

        {# ------ Column masking policies and PII tags ------ #}
        {# Tags are dropped by CREATE OR REPLACE TABLE exactly like policies,
           so re-apply PII_CATEGORY from column meta too — this keeps the
           CIS 4.3 check (tagged PII without masking) and the tag inventory
           accurate across rebuilds. #}
        {% for column in model.columns.values() %}
            {% set mask = column.meta.get('masking_policy') if column.meta else none %}
            {% if mask %}
                {% do run_query(
                    "ALTER TABLE " ~ this
                    ~ " MODIFY COLUMN " ~ column.name
                    ~ " SET MASKING POLICY " ~ mask ~ " FORCE"
                ) %}
                {{ log("Applied masking policy " ~ mask ~ " to " ~ this ~ "." ~ column.name, info=False) }}
            {% endif %}

            {% set pii_category = column.meta.get('pii_category') if column.meta else none %}
            {% if pii_category %}
                {% do run_query(
                    "ALTER TABLE " ~ this
                    ~ " MODIFY COLUMN " ~ column.name
                    ~ " SET TAG MONITORING_DB.AUDIT.PII_CATEGORY = '" ~ pii_category ~ "'"
                ) %}
            {% endif %}
        {% endfor %}

    {% endif %}
{% endmacro %}
