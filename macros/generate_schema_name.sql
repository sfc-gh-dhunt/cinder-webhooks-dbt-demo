{#-
    Custom schema naming.

    dbt's default behaviour concatenates the profile schema and the custom schema, which
    would give you CINDER_ANALYTICS.PUBLIC_STAGING instead of CINDER_ANALYTICS.STAGING.
    That default exists to stop developers colliding in a shared database; here the
    layer schemas are part of the design and should be named exactly as declared.

    Behaviour:
      - a model with a custom schema  ->  that schema, verbatim
      - a model with no custom schema ->  the profile's schema

    CI overrides this by passing a schema prefix, so pull-request builds still get their
    own namespace. See .github/workflows/ci.yml.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- set ci_prefix = var('cinder_schema_prefix', '') -%}

    {%- if custom_schema_name is none -%}
        {{ (ci_prefix ~ default_schema) | trim | upper }}
    {%- else -%}
        {{ (ci_prefix ~ custom_schema_name) | trim | upper }}
    {%- endif -%}

{%- endmacro %}
