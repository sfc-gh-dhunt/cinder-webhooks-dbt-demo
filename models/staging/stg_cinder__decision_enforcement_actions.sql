/*
    One row per decision per enforcement action.

    Enforcement actions arrive as a bare array of slugs — no ids, no names, no metadata.
    So the enforcement action dimension is built from the observed slugs rather than from
    any reference table, which means it only ever contains actions that have actually been
    applied. An action configured in Cinder but never used will not appear.

    `enforcement_actions_removed` is modelled here too, as a separate row flavour rather
    than a separate model, because "removed a ban" and "applied a ban" belong on the same
    axis for anything measuring net enforcement.
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
        , enforcement_actions
        , enforcement_actions_removed
    from {{ ref('stg_cinder__decisions') }}

),

applied as (

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
        , 'applied'                                 as action_disposition
        , a.index::number                           as action_ordinal
        , a.value::varchar                          as enforcement_action_slug
    from decisions d
    , lateral flatten(input => d.enforcement_actions) a

),

removed as (

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
        , 'removed'                                 as action_disposition
        , a.index::number                           as action_ordinal
        , a.value::varchar                          as enforcement_action_slug
    from decisions d
    , lateral flatten(input => d.enforcement_actions_removed) a

),

combined as (

    -- UNION ALL, not UNION. The two branches are disjoint by construction
    -- (action_disposition differs), so deduplication would do nothing except add a sort.
    select * from applied
    union all
    select * from removed

)

select
      {{ dbt_utils.generate_surrogate_key([
            'decision_event_sk', 'action_disposition', 'enforcement_action_slug', 'action_ordinal'
        ]) }}                                       as decision_enforcement_action_sk
    , decision_event_sk
    , decision_id
    , enforcement_action_slug
    , action_disposition
    , action_ordinal

    -- Signed so that summing gives net enforcement rather than gross activity.
    , case when action_disposition = 'applied' then 1 else -1 end
                                                    as enforcement_action_signed_count

    , decided_at
    , job_id
    , queue_slug
    , entity_schema
    , entity_id
    , decision_type
    , decision_actor_type
    , reviewer_email
from combined
