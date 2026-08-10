{#-
    ==================================================================================
    cinder_base_event_model
    ==================================================================================
    The whole body of a base model. All three base models are one call to this.

    Resolve where to read from, key each delivery, deduplicate, and surface the
    redelivery evidence. Deliberately does NOT interpret the payload — that belongs to
    staging, where the rules differ per event.

    Writing this once rather than three times matters more than it looks: deduplication
    is the step where a subtle inconsistency between events would be hardest to spot and
    most damaging. One implementation means one thing to review and one thing to fix.

    Columns produced
    ----------------
    event_sk         VARCHAR        surrogate delivery key (see cinder_event_sk)
    event            VARCHAR        webhook event name
    payload          VARIANT        webhook payload object, untouched
    first_seen_at    TIMESTAMP_NTZ  earliest ingestion time for this delivery
    last_seen_at     TIMESTAMP_NTZ  latest ingestion time for this delivery
    delivery_count   NUMBER         how many times it was delivered
    was_redelivered  BOOLEAN        delivery_count > 1
    record_source    VARCHAR        'raw' or 'seed'
-#}

{% macro cinder_base_event_model(event_table) %}

with source_events as (

    {{ cinder_raw_events(event_table) }}

),

keyed as (

    select
          {{ cinder_event_sk('event', 'payload') }}  as event_sk
        , record_source
        , event
        , payload
        , import_ts
    from source_events

),

deduplicated as (

    select
          event_sk
        , event
        , payload

        -- First time we saw this delivery. Retries arrive later, so MIN is the true
        -- arrival time.
        , min(import_ts)    as first_seen_at
        , max(import_ts)    as last_seen_at
        , count(*)          as delivery_count

        -- If the same payload arrives on both surfaces — which happens during a
        -- seed-to-raw migration — the raw surface wins, because it is the authoritative
        -- one.
        , case
              when max(case when record_source = 'raw' then 1 else 0 end) = 1 then 'raw'
              else 'seed'
          end               as record_source

    from keyed
    group by event_sk, event, payload

)

select
      event_sk
    , event
    , payload
    , first_seen_at
    , last_seen_at
    , delivery_count

    -- Surfaced rather than swallowed. Deduplication that silently discards the evidence
    -- of redelivery also discards a useful signal about endpoint health.
    , delivery_count > 1    as was_redelivered
    , record_source

from deduplicated

{% endmacro %}
