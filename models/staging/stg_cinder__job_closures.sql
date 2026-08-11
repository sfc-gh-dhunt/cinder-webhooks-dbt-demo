/*
    One row per job closure delivery.

    Two properties of this event determine how it can be used, and both understate
    activity if ignored:

      1. Cinder sends no `job.closed` event at all when a job closes with zero production
         decisions. So closure counts from this event are a floor, not a total. The
         reconciliation test in tests/ reports the gap rather than hiding it.

      2. The event is not subscribed by default on a new webhook endpoint. An empty source
         table usually means the subscription was never enabled, not that no jobs closed.

    The `decisions` array is not flattened here — it gets its own model, at decision grain,
    explicitly labelled as closure context rather than as the authoritative decision fact.
*/

with base as (

    select * from {{ ref('base_cinder__job_closed') }}

),

flattened as (

    select
          event_sk                                              as job_closure_event_sk

        , payload:job:id::varchar                               as job_id
        , {{ cinder_event_timestamp('payload:timestamp') }}     as closed_at
        , {{ cinder_event_timestamp('payload:job:created_at') }} as job_created_at

        -- This event names the category `category`; job.actioned names it
        -- `job_category`, and this one's enum is wider (it adds `training` and
        -- `multi_review`). Normalised to one column name here; the accepted-values test
        -- asserts the union of both enums.
        , {{ cinder_normalised_job_category('payload:job') }}    as job_category

        , payload:job:queue:slug::varchar                        as queue_slug
        , payload:job:queue:is_multi_review::boolean             as queue_is_multi_review

        , payload:job:entity:entity_schema::varchar              as entity_schema
        , payload:job:entity:attributes:id::varchar              as entity_id
        , payload:job:entity:attributes                          as entity_attributes

        , payload:decisions                                      as closure_decisions

        , first_seen_at
        , delivery_count
        , was_redelivered
        , record_source

    from base

),

derived as (

    select
          *

        , array_size(coalesce(closure_decisions, array_construct()))
                                                    as closure_decision_count

        -- Time in review, from job creation to closure. Null rather than zero when
        -- creation time is missing — a fabricated zero would look like instant
        -- resolution and flatter the numbers.
        , case
              when job_created_at is not null and closed_at is not null
              then datediff('second', job_created_at, closed_at)
          end                                       as time_to_close_seconds

    from flattened

)

select
      job_closure_event_sk
    , job_id
    , closed_at
    , job_created_at
    , time_to_close_seconds
    , job_category
    , queue_slug
    , queue_is_multi_review
    , entity_schema
    , entity_id
    , entity_attributes
    , closure_decisions
    , closure_decision_count
    , first_seen_at
    , delivery_count
    , was_redelivered
    , record_source
from derived
