/*
    One row per decision recorded inside a job.closed event.

    CLOSURE CONTEXT ONLY — NOT THE DECISION FACT.

    The same decisions are delivered twice by Cinder: once each on `decision.created`, and
    again bundled into the `decisions` array of `job.closed`. Modelling both as facts would
    double-count every decision on any closed job.

    So `stg_cinder__decisions` is authoritative for the decision grain, and this model
    exists for two narrower purposes:

      1. Reconciliation. Comparing the two surfaces detects decisions that never arrived on
         `decision.created` — which is exactly what you see when that event is not routed,
         or when a subscription was enabled late.

      2. Salvage. If `decision.created` is not being ingested at all, this is the only
         decision-level data available. It is thinner: no decision id, no policy metadata
         beyond id and name, no predictions, no point updates, and only a coarse
         `source.type` instead of the full decision type enum.

    Nothing downstream of the marts should join to this model for decision metrics.
*/

with closures as (

    select
          job_closure_event_sk
        , job_id
        , closed_at
        , job_category
        , queue_slug
        , closure_decisions
    from {{ ref('stg_cinder__job_closures') }}

),

exploded as (

    select
          c.job_closure_event_sk
        , c.job_id
        , c.closed_at
        , c.job_category
        , c.queue_slug

        , d.index::number                                       as closure_decision_ordinal
        , {{ cinder_event_timestamp('d.value:timestamp') }}      as decided_at

        -- Coarse: this array carries only source.type, not the full decision type enum
        -- available on decision.created.
        , d.value:source:type::varchar                           as decision_source_type

        , d.value:entity:entity_schema::varchar                  as entity_schema
        , d.value:entity:attributes:id::varchar                  as entity_id
        , d.value:policies                                       as policies
        , d.value:enforcement_actions                            as enforcement_actions

    from closures c
    , lateral flatten(input => c.closure_decisions) d

)

select
      {{ dbt_utils.generate_surrogate_key(['job_closure_event_sk', 'closure_decision_ordinal']) }}
                                                                as closure_decision_sk
    , job_closure_event_sk
    , job_id
    , closed_at
    , decided_at
    , job_category
    , queue_slug
    , decision_source_type
    , entity_schema
    , entity_id
    , policies
    , enforcement_actions
    , array_size(coalesce(policies, array_construct()))          as policy_count
    , array_size(coalesce(enforcement_actions, array_construct())) as enforcement_action_count
    , closure_decision_ordinal
from exploded
