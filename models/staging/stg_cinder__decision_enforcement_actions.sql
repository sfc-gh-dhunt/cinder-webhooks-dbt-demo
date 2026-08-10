/*
    One row per decision per enforcement action.

    Enforcement arrives twice in each decision, at two different grains, and the difference
    matters:

      * `decision.enforcement_actions` — the union of actions across the whole decision.
        This is what was actually applied to the entity.
      * `policy.enforcement_actions` — the actions attributable to each individual policy.

    This model uses the DECISION-LEVEL array, because it answers "what enforcement was
    applied". Summing the per-policy arrays instead would double-count any action that two
    policies both call for, which is common — several harassment policies all warn.

    Per-policy attribution lives in stg_cinder__decision_policies, where it belongs.

    Actions arrive as bare slugs: no ids, no display names, no severity. So the enforcement
    dimension is built from observed usage and severity is a local convention. See
    dim_enforcement_action.
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
        , enforcement_actions
        , enforcement_action_count
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
        , d.enforcement_action_count                        as actions_on_decision

        , a.index::number                                   as action_ordinal
        , a.value::varchar                                  as enforcement_action_slug

    from decisions d
    , lateral flatten(input => d.enforcement_actions) a

)

select
      {{ cinder_surrogate_key(['decision_sk', 'enforcement_action_slug', 'action_ordinal']) }}
                                                            as decision_enforcement_action_sk
    , decision_sk
    , job_closure_event_sk
    , enforcement_action_slug
    , action_ordinal
    , actions_on_decision

    -- `no_action` is a recorded outcome, not an absence of one. Counting it as enforcement
    -- inflates every enforcement metric, so it is flagged rather than filtered — the
    -- decision about whether to include it belongs to the consumer, not to this model.
    , enforcement_action_slug = 'no_action'                 as is_no_action

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
