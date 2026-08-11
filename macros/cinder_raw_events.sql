{#-
    ==================================================================================
    cinder_raw_events
    ==================================================================================
    Single entry point for reading a Cinder event stream, whether it comes from the
    synthetic seeds, from the real landing tables, or from both.

    Why this exists
    ---------------
    Three things are true at once in a real deployment, and all three have to be handled
    without editing model code:

      1. A fresh clone has no data at all, so the project must be able to run entirely
         off seeds. Otherwise nobody can evaluate it.
      2. Some event types are usually already being ingested while others are not yet
         routed. So the seed-or-raw decision has to be per event, not global.
      3. A landing table for an unrouted event may not exist yet. A project that fails
         to compile because a table is missing is a project that blocks the ingestion
         team's work.

    Arguments
    ---------
    event_table  Name of the event, matching both the source table name and the seed
                 name: 'job_actioned', 'job_closed', 'decision_created'.

    Returns
    -------
    SQL producing exactly these columns:

      record_source  VARCHAR        'seed' or 'raw' — which surface the row came from
      event          VARCHAR        the webhook event name
      payload        VARIANT        the webhook payload object
      import_ts      TIMESTAMP_NTZ  ingestion wall-clock time (NOT event time)

    Modes
    -----
    Controlled by var('cinder_source_mode'), overridable per event via
    var('cinder_source_mode_by_event'):

      seed   read the seeds only              (default)
      raw    read the landing table only
      union  read both

    If mode includes raw and the landing table does not exist, the raw branch is
    dropped with a log message rather than failing. If that leaves nothing to read at
    all, an empty, correctly-typed result is returned so downstream models still build.
-#}

{% macro cinder_raw_events(event_table) %}

    {%- set valid_modes = ['seed', 'raw', 'union'] -%}
    {%- set overrides = var('cinder_source_mode_by_event', {}) -%}
    {%- set mode = (overrides.get(event_table, var('cinder_source_mode')) | lower) -%}

    {%- if mode not in valid_modes -%}
        {{ exceptions.raise_compiler_error(
            "Invalid source mode '" ~ mode ~ "' for event '" ~ event_table ~ "'. "
            ~ "Expected one of: " ~ valid_modes | join(', ')
        ) }}
    {%- endif -%}

    {%- set branches = [] -%}

    {#- ---------------------------------------------------------------- seed branch -#}
    {%- if mode in ['seed', 'union'] -%}
        {%- set seed_sql -%}
            select
                  'seed'                          as record_source
                , event                           as event
                -- A seed cannot carry a VARIANT, so the payload arrives as text.
                -- TRY_PARSE_JSON rather than PARSE_JSON: a malformed seed row should
                -- surface as a null payload and get caught by a test, not blow up the
                -- whole build.
                , try_parse_json(payload)         as payload
                , import_ts                      as import_ts
            from {{ ref('seed_cinder_' ~ event_table) }}
        {%- endset -%}
        {%- do branches.append(seed_sql) -%}
    {%- endif -%}

    {#- ----------------------------------------------------------------- raw branch -#}
    {%- if mode in ['raw', 'union'] -%}
        {%- set src = source('cinder', event_table) -%}
        {%- set raw_available = true -%}

        {#- Relation lookups only work during execution, not during parsing. -#}
        {%- if execute -%}
            {%- set existing = adapter.get_relation(
                    database=src.database,
                    schema=src.schema,
                    identifier=src.identifier
                ) -%}
            {%- if existing is none -%}
                {%- set raw_available = false -%}
                {{ log(
                    "[cinder] Source table " ~ src ~ " does not exist — skipping the raw "
                    ~ "branch for '" ~ event_table ~ "'. This is expected while the event "
                    ~ "is not yet routed by the ingestion layer.",
                    info=True
                ) }}
            {%- endif -%}
        {%- endif -%}

        {%- if raw_available -%}
            {%- set raw_sql -%}
                select
                      'raw'         as record_source
                    , event         as event
                    , payload       as payload
                    , import_ts     as import_ts
                from {{ src }}
            {%- endset -%}
            {%- do branches.append(raw_sql) -%}
        {%- endif -%}
    {%- endif -%}

    {#- ------------------------------------------------------------ empty fallback -#}
    {%- if branches | length == 0 -%}
        {{ log(
            "[cinder] No readable surface for '" ~ event_table ~ "' — emitting an empty "
            ~ "result so downstream models still build.",
            info=True
        ) }}
        select
              cast(null as varchar)       as record_source
            , cast(null as varchar)       as event
            , cast(null as variant)       as payload
            , cast(null as timestamp_ntz) as import_ts
        where false
    {%- else -%}
        {#- UNION ALL, never UNION. Deduplication is an explicit, testable step in the
            base models keyed on the event surrogate key — not a silent side effect of
            set semantics. UNION here would also be a needless sort. -#}
        {{ branches | join('\n\n        union all\n\n        ') }}
    {%- endif -%}

{% endmacro %}
