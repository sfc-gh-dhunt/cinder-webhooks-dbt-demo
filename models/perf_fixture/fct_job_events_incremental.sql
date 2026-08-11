/*
    Incremental fixture — the only hand-written incremental model in this project, and it
    exists for the CI performance gate rather than for the demo.

    WHY IT IS HERE AT ALL. Every mart in this project is a dynamic table, which is the better
    answer for this workload: incrementality is declared and Snowflake maintains it. But the
    failure the performance gate is built to catch is specifically an INCREMENTAL model whose
    watermark stops pruning as the target grows — a merge that quietly rescans everything and
    goes from seconds to a timeout as the table gets bigger. There is nothing in this project
    that can fail that way, so the gate had nothing to be demonstrated against.

    WHAT MAKES THIS SHAPE THE INTERESTING ONE. The watermark reads MAX from the model's own
    target and subtracts a lookback window:

        where event_ts >= (select max(event_ts) from {{ this }}) - interval '3 hours'

    That is the pattern most incremental models in the wild are written with, and its
    performance depends entirely on something invisible in the SQL: whether the source is
    physically ordered such that a predicate on EVENT_TS can eliminate micro-partitions at
    compile time. Read the code and you cannot tell. Read the query plan and it is a number.

    THE LOOKBACK IS DELIBERATE, NOT SLOPPY. Events arrive up to 72 hours after they happen
    (see the source docs), so a 3-hour lookback on event time is genuinely too narrow and will
    drop late rows. That is a correctness bug, and it is left in place on purpose to mark the
    boundary the gate does not cross: judging whether a watermark column is semantically the
    right one is code review, which this project already runs. The gate answers the question
    code review cannot — whether the predicate prunes against production volumes — and says
    nothing about whether the window is wide enough. Two different jobs.
*/

{{ config(
    materialized='incremental',
    unique_key='event_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
) }}

select
    src.event_id,
    src.job_id,
    src.event,
    src.queue_slug,
    src.actor_email,
    src.event_ts,
    src.import_ts,
    src.payload:trace_id::varchar                    as trace_id,
    src.payload:content_fingerprint::varchar         as content_fingerprint,
    datediff('minute', src.event_ts, src.import_ts)  as ingestion_lag_minutes

from {{ source('cinder_volume', 'job_events_volume') }} src

{% if is_incremental() %}
    -- Only reachable once the target exists. On the first build this branch is absent and the
    -- model reads the whole source, which is expected and is not what the gate is looking for.
    where src.event_ts >= (
        select coalesce(max(tgt.event_ts), '1900-01-01'::timestamp_ntz)
        from {{ this }} tgt
    ) - interval '3 hours'
{% endif %}
