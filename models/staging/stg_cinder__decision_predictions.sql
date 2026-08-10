/*
    One row per classifier prediction attached to a decision's entity.

    Predictions are the bridge between automated classification and human judgement, so
    this is the grain where classifier precision can be measured: compare the prediction's
    policy against the policy the decision actually applied.

    Two things the schema documents that matter here:

      * `score` is present "when available" — so it is genuinely nullable, and a
         null score is not the same as a score of zero.
      * `confidence` is derived by Cinder from the score against configured thresholds.
         It is therefore a function of configuration, not of the model alone: the same
         score can be HIGH today and MEDIUM after a threshold change. Trend analysis on
         confidence needs that caveat; trend analysis on score does not.
*/

with decisions as (

    select
          decision_event_sk
        , decision_id
        , decided_at
        , job_id
        , entity_schema
        , entity_id
        , entity_predictions
        , policies
    from {{ ref('stg_cinder__decisions') }}
    where entity_predictions is not null

),

exploded as (

    select
          d.decision_event_sk
        , d.decision_id
        , d.decided_at
        , d.job_id
        , d.entity_schema
        , d.entity_id
        , d.policies

        , p.index::number                           as prediction_ordinal
        , p.value:inference_id::varchar             as inference_id
        , p.value:policy_id::varchar                 as predicted_policy_id
        , p.value:confidence::varchar                as prediction_confidence
        , p.value:score::float                       as prediction_score
        , p.value:is_positive::boolean               as prediction_is_positive
        , p.value:attributes                         as predicted_on_attributes

    from decisions d
    , lateral flatten(input => d.entity_predictions) p

),

with_outcome as (

    select
          e.*

        -- Did the decision actually apply the policy the classifier predicted?
        -- ARRAY_CONTAINS over the decision's policy ids, rather than a join, because the
        -- question is about set membership on the same row — a join would fan the row out
        -- once per policy and break the grain.
        , array_contains(
              e.predicted_policy_id::variant,
              coalesce(
                  transform(e.policies, p variant -> p:id::varchar),
                  array_construct()
              )
          )                                         as prediction_matched_decision

    from exploded e

)

select
      {{ dbt_utils.generate_surrogate_key(['decision_event_sk', 'inference_id', 'prediction_ordinal']) }}
                                                    as decision_prediction_sk
    , decision_event_sk
    , decision_id
    , inference_id
    , predicted_policy_id
    , prediction_confidence
    , prediction_score
    , prediction_is_positive
    , predicted_on_attributes
    , prediction_matched_decision
    , prediction_ordinal
    , decided_at
    , job_id
    , entity_schema
    , entity_id
from with_outcome
