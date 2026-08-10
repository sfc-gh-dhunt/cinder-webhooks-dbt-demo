/*
    One row per appeal resolved by a decision.

    A single decision can resolve more than one appeal, so this is its own grain.

    This model uses `appeals_resolved` rather than the legacy signals, on purpose. Cinder's
    documentation recommends it as the future-proof way to detect an appeal outcome, over
    both the deprecated `appeal` field and the legacy appeal-specific decision types
    (`override`, `confirm`, `revert`). Those legacy types still appear in historical data,
    so a model keyed on them would work on old rows and quietly stop working on new ones.

    `appealer` is nullable — the documentation states it can be absent when the appealing
    party was not supplied. Null means "not recorded", not "anonymous".
*/

with decisions as (

    select
          decision_event_sk
        , decision_id
        , decided_at
        , job_id
        , queue_slug
        , decision_type
        , reviewer_email
        , entity_schema
        , entity_id
        , appeals_resolved
        , override_chain_depth
    from {{ ref('stg_cinder__decisions') }}
    where appeals_resolved is not null

),

exploded as (

    select
          d.decision_event_sk
        , d.decision_id
        , d.decided_at
        , d.job_id
        , d.queue_slug
        , d.decision_type
        , d.reviewer_email
        , d.entity_schema
        , d.entity_id
        , d.override_chain_depth

        , a.index::number                                   as appeal_ordinal
        , a.value:outcome::varchar                           as appeal_outcome
        , a.value:source::varchar                            as appeal_source
        , a.value:appealer:entity_schema::varchar            as appealer_entity_schema
        , a.value:appealer:attributes:id::varchar            as appealer_entity_id
        , a.value:appealer                                   as appealer

    from decisions d
    , lateral flatten(input => d.appeals_resolved) a

)

select
      {{ dbt_utils.generate_surrogate_key(['decision_event_sk', 'appeal_ordinal']) }}
                                                            as decision_appeal_sk
    , decision_event_sk
    , decision_id
    , appeal_outcome
    , appeal_source
    , appealer_entity_schema
    , appealer_entity_id
    , appealer

    -- The two outcomes that changed the original decision, versus the one that upheld it.
    -- Grouping them is the basis of an overturn rate, and doing it here means every
    -- consumer computes it the same way.
    , appeal_outcome in ('accepted', 'adjustment')           as appeal_changed_outcome

    , appeal_ordinal
    , decided_at
    , job_id
    , queue_slug
    , decision_type
    , reviewer_email
    , entity_schema
    , entity_id
    , override_chain_depth
from exploded
