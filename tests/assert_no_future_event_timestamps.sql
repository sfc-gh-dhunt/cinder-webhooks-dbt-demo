/*
    No event may be timestamped in the future.

    A future event time means one of three things, all worth knowing: a clock skew on the
    sending side, a timezone bug in the parsing, or fabricated data. Any of them will quietly
    distort every time-based metric — a decision dated next week lands in no current period
    and disappears from the trend.

    A tolerance is allowed because the sending system's clock is not ours, and a few seconds
    of skew is normal rather than a defect. Widen it with the
    `cinder_future_event_tolerance_hours` var if the sending system is known to drift.
*/

with events as (

    select 'job.actioned' as event_name, job_action_event_sk as event_key, actioned_at as event_at
    from {{ ref('stg_cinder__job_actions') }}

    union all

    select 'job.closed', job_closure_event_sk, closed_at
    from {{ ref('stg_cinder__job_closures') }}

    union all

    select 'decision', decision_sk, decided_at
    from {{ ref('stg_cinder__decisions') }}

)

select
      event_name
    , event_key
    , event_at
    , current_timestamp() as checked_at
from events
where event_at > dateadd('hour', {{ var('cinder_future_event_tolerance_hours') }}, current_timestamp())
