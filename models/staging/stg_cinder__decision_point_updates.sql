/*
    One row per point update recorded by a decision.

    Points are Cinder's weighted risk score. A decision can move points on an entity other
    than the one under review — a decision on a post can add points to its author — so the
    entity on the point update is captured separately from the entity on the decision.
    Assuming they are the same misattributes risk to content instead of accounts.

    `points_total` is the balance after the change, supplied by Cinder. It is not
    recomputed here: a running sum over these rows would diverge from Cinder's own figure
    whenever points expire or are adjusted outside a decision, and Cinder's figure is the
    one that drives enforcement thresholds.
*/

with decisions as (

    select
          decision_event_sk
        , decision_id
        , decided_at
        , job_id
        , entity_schema     as decision_entity_schema
        , entity_id         as decision_entity_id
        , point_updates
    from {{ ref('stg_cinder__decisions') }}
    where point_updates is not null

),

exploded as (

    select
          d.decision_event_sk
        , d.decision_id
        , d.decided_at
        , d.job_id
        , d.decision_entity_schema
        , d.decision_entity_id

        , u.index::number                                       as point_update_ordinal
        , u.value:points_change::number                          as points_change
        , u.value:points_total::number                           as points_total
        , u.value:entity:entity_schema::varchar                   as scored_entity_schema
        , u.value:entity:attributes:id::varchar                   as scored_entity_id

    from decisions d
    , lateral flatten(input => d.point_updates) u

)

select
      {{ dbt_utils.generate_surrogate_key(['decision_event_sk', 'point_update_ordinal']) }}
                                                                as decision_point_update_sk
    , decision_event_sk
    , decision_id
    , points_change
    , points_total
    , scored_entity_schema
    , scored_entity_id
    , decision_entity_schema
    , decision_entity_id

    -- Whether the points landed on something other than the entity being reviewed.
    -- Usually true when a post-level decision penalises the account behind it.
    , scored_entity_id is distinct from decision_entity_id
                                                                as scored_other_entity

    , point_update_ordinal
    , decided_at
    , job_id
from exploded
