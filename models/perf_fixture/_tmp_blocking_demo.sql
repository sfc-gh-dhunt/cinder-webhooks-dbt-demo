/*
    TEMPORARY — reverted in the next commit.

    Exists to demonstrate the performance gate failing a pull request. The join predicate is a
    non-equi comparison, which cannot be used as a join key, so Snowflake resolves it to a
    CartesianJoin: every row of a 50M-row table compared against every row of the dimension.

    That is the one finding the gate blocks on, because it is the one that involves no estimate.
    The optimiser names it in the plan, and there is no data volume at which it becomes acceptable.

    Expect two things in CI: the gate fails, and the build job is SKIPPED rather than run — there
    is no reason to pay for a build of a change already known to be pathological.
*/

{{ config(materialized='view') }}

select
    v.job_id
    , v.event_ts
    , q.queue_slug
from {{ source('cinder_volume', 'job_events_volume') }} v
inner join {{ ref('dim_queue') }} q
    on v.queue_slug > q.queue_slug
