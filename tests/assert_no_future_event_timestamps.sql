{{ config(severity='error') }}

/*
    No event may be timestamped in the future.

    A future event time means one of three things, all worth knowing: clock skew on the sending
    side, a timezone bug in the parsing, or fabricated data. Any of them quietly distorts every
    time-based metric — a decision dated next week lands in no current period and vanishes from
    the trend.

    A tolerance is allowed because the sending system's clock is not ours, and a few seconds of
    skew is normal rather than a defect. Widen it with `cinder_future_event_tolerance_hours` if
    the sending system is known to drift.
*/

with events as (

    select
          'job.actioned'            as event_name
        , job_action_event_sk       as event_key
        , actioned_at               as event_at
    from {{ ref('stg_cinder__job_actions') }}

    union all

    select
          'job.closed'              as event_name
        , job_closure_event_sk      as event_key
        , closed_at                 as event_at
    from {{ ref('stg_cinder__job_closures') }}

    union all

    select
          'decision'                as event_name
        , decision_sk               as event_key
        , decided_at                as event_at
    from {{ ref('stg_cinder__decisions') }}

)

select
      event_name
    , event_key
    , event_at
from events
where event_at > dateadd(
    'hour',
    {{ var('cinder_future_event_tolerance_hours') }},
    current_timestamp()
)
