/*
    One row per decision per applied policy.

    The grain for every per-policy question: which policies drive the most enforcement,
    how distribution shifts over time, how much of each policy's volume is automated.

    TWO UNDOCUMENTED FIELDS ARE MODELLED HERE, because they appear in practice and both
    change what you can answer:

      * `parent_id` — policies form a hierarchy. A policy tree has broad areas at the top
        and specific violations beneath. Distribution reported at leaf level fragments into
        dozens of thin slices; rolled up to the parent it becomes readable. `parent_id` is
        ABSENT on root policies rather than null, so the model handles a missing key.

      * `enforcement_actions` nested inside each policy — the actions attributable to that
        specific policy, as opposed to the decision-level array which is the union across
        all policies on the decision. Attributing enforcement to a policy needs the nested
        one; counting enforcement per decision needs the decision-level one. Conflating
        them double-counts on any multi-policy decision.
*/

with decisions as (

    select
          decision_sk
        , job_closure_event_sk
        , job_id
        , decided_at
        , closed_at
        , job_category
        , queue_slug
        , entity_schema
        , entity_id
        , decision_source_type
        , is_automated
        , is_human_decision
        , reviewer_email
        , handle_time_seconds
        , policy_count
        , policies
    from {{ ref('stg_cinder__decisions') }}

),

exploded as (

    select
          d.decision_sk
        , d.job_closure_event_sk
        , d.job_id
        , d.decided_at
        , d.closed_at
        , d.job_category
        , d.queue_slug
        , d.entity_schema
        , d.entity_id
        , d.decision_source_type
        , d.is_automated
        , d.is_human_decision
        , d.reviewer_email
        , d.handle_time_seconds
        , d.policy_count                                    as policies_on_decision

        , p.index::number                                   as policy_ordinal
        , p.value:id::varchar                               as policy_id
        , p.value:name::varchar                             as policy_name

        -- Absent on root policies. Left null, and `is_root_policy` below makes the
        -- distinction explicit rather than leaving every consumer to infer it.
        , p.value:parent_id::varchar                        as policy_parent_id

        , p.value:is_illegal::boolean                       as policy_is_illegal
        , p.value:is_non_violating::boolean                 as policy_is_non_violating
        , p.value:customer_ref::varchar                     as policy_customer_ref

        -- Per-policy enforcement, not the decision-level union.
        , p.value:enforcement_actions                       as policy_enforcement_actions

    from decisions d
    , lateral flatten(input => d.policies) p

)

select
      {{ cinder_surrogate_key(['decision_sk', 'policy_id', 'policy_ordinal']) }}
                                                            as decision_policy_sk
    , decision_sk
    , job_closure_event_sk
    , policy_id
    , policy_name
    , policy_parent_id
    , policy_parent_id is null                              as is_root_policy
    , policy_is_illegal
    , policy_is_non_violating
    , policy_customer_ref
    , policy_enforcement_actions
    , array_size(coalesce(policy_enforcement_actions, array_construct()))
                                                            as policy_enforcement_action_count
    , policy_ordinal
    , policy_ordinal = 0                                    as is_primary_policy
    , policies_on_decision

    -- Fractional allocation, so summing across policies returns the true decision count
    -- rather than a multiple of it. Use this when "decisions by policy" must add up to
    -- total decisions; use the raw row count when you want policy application volume.
    , 1.0 / nullif(policies_on_decision, 0)                 as decision_count_allocated

    , decided_at
    , closed_at
    , job_id
    , job_category
    , queue_slug
    , entity_schema
    , entity_id
    , decision_source_type
    , is_automated
    , is_human_decision
    , reviewer_email
    , handle_time_seconds
from exploded
