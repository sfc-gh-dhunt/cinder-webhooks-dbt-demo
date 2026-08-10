/*
    Conformed queue dimension.

    Built by union, because no event carries a queue record. Every event carries a queue
    *fragment* — slug and multi-review flag — and the dimension is assembled from all
    three. This is the honest way to build a dimension from a webhook surface, and it has
    two consequences worth stating plainly:

      1. The dimension only ever contains queues that have had activity. A queue
         configured in Cinder but never used will not appear here. It is an observed
         dimension, not a reference one.

      2. There is no queue id. The slug is the only identifier the webhooks expose, so it
         is the business key. If a queue is renamed in Cinder and its slug changes, it
         will appear here as two queues, and history will not follow the rename.

    `is_multi_review` is taken from the most recent observation rather than the first,
    because it is a mutable queue setting and the current value is the useful one.
*/

with queue_fragments as (

    select
          queue_slug
        , queue_is_multi_review
        , actioned_at        as observed_at
        , 'job.actioned'     as observed_on_event
    from {{ ref('stg_cinder__job_actions') }}
    where queue_slug is not null

    union all

    select
          queue_slug
        , queue_is_multi_review
        , closed_at          as observed_at
        , 'job.closed'       as observed_on_event
    from {{ ref('stg_cinder__job_closures') }}
    where queue_slug is not null

    union all

    select
          queue_slug
        , queue_is_multi_review
        , decided_at         as observed_at
        , 'decision.created' as observed_on_event
    from {{ ref('stg_cinder__decisions') }}
    where queue_slug is not null

),

aggregated as (

    select
          queue_slug
        , min(observed_at)                                  as first_seen_at
        , max(observed_at)                                  as last_seen_at
        , count(*)                                          as observation_count
        , count(distinct observed_on_event)                 as observed_event_type_count
    from queue_fragments
    group by queue_slug

),

latest_attributes as (

    select
          queue_slug
        , queue_is_multi_review
    from queue_fragments
    qualify row_number() over (
        partition by queue_slug
        order by observed_at desc nulls last
    ) = 1

)

select
      {{ cinder_surrogate_key(['a.queue_slug']) }}  as queue_key
    , a.queue_slug
    , l.queue_is_multi_review

    -- Readable label for a semantic layer. Slugs are machine-facing; a reviewer asking
    -- "how many decisions in flagged text" should not have to know the hyphenation.
    , initcap(replace(a.queue_slug, '-', ' '))                as queue_name

    , a.first_seen_at
    , a.last_seen_at
    , a.observation_count
    , a.observed_event_type_count
from aggregated a
inner join latest_attributes l
    on a.queue_slug = l.queue_slug
