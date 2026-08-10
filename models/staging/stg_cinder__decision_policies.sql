/*
    One row per decision per policy.

    A decision can apply several policies at once. Any per-policy metric — which policies
    drive the most enforcement, which are most contested on appeal — needs this grain.
    Aggregating from stg_cinder__decisions instead would either undercount multi-policy
    decisions or, if you joined naively, fan the decision count out by policy and inflate it.

    `customer_ref` is nullable. It is the optional mapping back to the customer's own
    policy register, and a real policy tree has gaps in it.
*/

with decisions as (

    select
          decision_event_sk
        , decision_id
        , decided_at
        , job_id
        , queue_slug
        , entity_schema
        , entity_id
        , decision_type
        , decision_actor_type
        , reviewer_email
        , policies
    from {{ ref('stg_cinder__decisions') }}

),

exploded as (

    select
          d.decision_event_sk
        , d.decision_id
        , d.decided_at
        , d.job_id
        , d.queue_slug
        , d.entity_schema
        , d.entity_id
        , d.decision_type
        , d.decision_actor_type
        , d.reviewer_email

        , p.index::number                                   as policy_ordinal
        , p.value:id::varchar                               as policy_id
        , p.value:name::varchar                             as policy_name
        , p.value:customer_ref::varchar                     as policy_customer_ref
        , p.value:is_illegal::boolean                       as policy_is_illegal
        , p.value:is_non_violating::boolean                 as policy_is_non_violating

    from decisions d
    -- LATERAL FLATTEN, not a join to a separate array table: this preserves the parent
    -- row's context on every child row without any risk of a mismatched join key.
    , lateral flatten(input => d.policies) p

)

select
      {{ dbt_utils.generate_surrogate_key(['decision_event_sk', 'policy_id', 'policy_ordinal']) }}
                                                            as decision_policy_sk
    , decision_event_sk
    , decision_id
    , policy_id
    , policy_name
    , policy_customer_ref
    , policy_is_illegal
    , policy_is_non_violating
    , policy_ordinal
    , decided_at
    , job_id
    , queue_slug
    , entity_schema
    , entity_id
    , decision_type
    , decision_actor_type
    , reviewer_email
from exploded
