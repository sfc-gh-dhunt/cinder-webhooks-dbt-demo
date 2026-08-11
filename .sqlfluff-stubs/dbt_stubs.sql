{#-
    ==================================================================================
    Stub macros, for linting only
    ==================================================================================
    sqlfluff needs to render Jinja before it can parse SQL. Its dbt templater does this by
    compiling the project, which opens a database connection — so linting would need
    warehouse credentials, and a lint step that needs credentials cannot run as a cheap
    pre-flight check.

    These stubs let the jinja templater render every macro this project uses into something
    syntactically valid, with no connection and no dbt installation involved.

    THEY ARE NOT USED AT RUNTIME. dbt never sees this directory; only sqlfluff loads it, via
    load_macros_from_path in .sqlfluff. The real macros live in macros/.

    The rendered SQL only has to PARSE. It does not have to be semantically meaningful — the
    linter is checking formatting and syntax, not results. That is why `ref` can return a
    fixed name.

    If you add a macro that is called from a model, add a stub for it here or linting will
    fail with "'X' is undefined".
-#}

{% macro ref(model_name, v=none) %}db.schema.{{ model_name }}{% endmacro %}

{% macro source(source_name, table_name) %}db.schema.{{ table_name }}{% endmacro %}

{#- Must accept arbitrary keyword arguments, because models pass materialized, unique_key,
    incremental_strategy and others.

    Jinja macros do not support Python's **kwargs syntax. Instead, a macro gains access to a
    special `kwargs` variable only if its body REFERENCES that name — so the otherwise-pointless
    assignment below is what makes this stub accept keyword arguments at all. Remove it and
    every model fails with "macro 'config' takes no keyword argument". -#}
{% macro config() %}{%- set _ignored = kwargs -%}{% endmacro %}

{#- `this` is NOT defined here. It is a dbt VARIABLE, not a callable, so models write
    `{{ this }}` rather than `{{ this() }}`. Defined as a macro it renders as a macro object,
    which produces an unparsable section rather than a table name. It is set as a templater
    context variable in .sqlfluff instead. -#}

{% macro is_incremental() %}False{% endmacro %}

{#- var() has to return the right SHAPE per variable, not just a value: one of these is
    interpolated inside quotes as a date, another is used as a bare number in a DATEADD. A
    single generic return value would render invalid SQL for one of them. -#}
{% macro var(name, default=none) %}
    {%- if name == 'cinder_min_plausible_event_date' -%}2020-01-01
    {%- elif name == 'cinder_future_event_tolerance_hours' -%}1
    {%- elif name == 'raw_database' -%}db
    {%- elif name == 'raw_schema' -%}schema
    {%- elif name == 'cinder_source_mode' -%}seed
    {%- elif name == 'cinder_schema_prefix' -%}
    {%- elif name == 'cinder_source_mode_by_event' -%}{}
    {%- else -%}stub_value
    {%- endif -%}
{% endmacro %}

{#- Project macros. Each renders a syntactically valid fragment in the position where the
    real macro is used. -#}

{% macro cinder_surrogate_key(columns) %}md5('surrogate_key_stub'){% endmacro %}

{% macro cinder_event_sk(event_column='event', payload_column='payload') %}
md5({{ event_column }} || to_json({{ payload_column }}))
{% endmacro %}

{% macro cinder_event_timestamp(json_path) %}try_to_timestamp_tz({{ json_path }}::varchar){% endmacro %}

{% macro cinder_normalised_job_category(job_object) %}
coalesce({{ job_object }}:job_category::varchar, {{ job_object }}:category::varchar)
{% endmacro %}

{#- Returns the shape the real macro returns: the four columns the base layer expects. -#}
{% macro cinder_raw_events(event_table) %}
select
      'seed'                    as record_source
    , event                     as event
    , try_parse_json(payload)   as payload
    , import_ts                 as import_ts
from db.schema.seed_cinder_{{ event_table }}
{% endmacro %}

{#- The whole body of a base model, so base models render as complete statements. -#}
{% macro cinder_base_event_model(event_table) %}
select
      md5(event || to_json(payload))    as event_sk
    , event                             as event
    , payload                           as payload
    , min(import_ts)                    as first_seen_at
    , max(import_ts)                    as last_seen_at
    , count(*)                          as delivery_count
    , count(*) > 1                      as was_redelivered
    , 'seed'                            as record_source
from db.schema.seed_cinder_{{ event_table }}
group by event, payload
{% endmacro %}
