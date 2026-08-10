/*
    No event may predate the plausible start of the data.

    Catches the failure mode where a timestamp fails to parse into something sensible and
    lands at or near the epoch. A 1970 decision is not a data point, it is a parsing bug, and
    it will drag any date-range filter or earliest-event calculation with it.

    Widen `cinder_min_plausible_event_date` if you are loading a genuine historical backfill.
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
from events
where event_at < '{{ var('cinder_min_plausible_event_date') }}'::timestamp_tz
