/*
    Decision fact grain — one row per decision recorded on a closed job.

    THIS IS THE ONLY DECISION SURFACE. Cinder also emits `decision.created`, which is
    richer — it carries decision ids, classifier predictions, point updates, appeal
    outcomes and override chains. That event is out of scope here, so every decision-level
    measure in this project comes from the `decisions` array inside `job.closed`.

    What that costs you, stated plainly, because it determines which questions are
    answerable:

      * No decision id. The key is synthesised from the closure key plus the decision's
        position in the array.
      * A coarse `source.type` instead of the fourteen-value decision type enum. You can
        tell human from automated, but not `bulk_action` from `api_decision`.
      * No classifier predictions, point updates, appeal outcomes or override chains.
      * Decisions on jobs that never closed do not appear at all, and Cinder sends no
        `job.closed` when a job closes with zero decisions — so this is a floor on
        decision volume, not a total.

    What it gives you, which is most of what matters operationally: who decided, when,
    under which policies, with which enforcement, in which queue, on which entity type.

    The policy objects here carry two fields the published schema does not document: a
    `parent_id` forming a policy hierarchy, and a nested per-policy `enforcement_actions`
    array. Both are modelled — see stg_cinder__decision_policies.
*/

with closures as (

    select
          job_closure_event_sk
        , job_id
        , closed_at
        , job_created_at
        , job_category
        , queue_slug
        , queue_is_multi_review
        , entity_schema        as job_entity_schema
        , entity_id            as job_entity_id
        , closure_decisions
        , closure_decision_count
        , first_seen_at
        , delivery_count
        , was_redelivered
        , record_source
    from {{ ref('stg_cinder__job_closures') }}

),

exploded as (

    select
          c.job_closure_event_sk
        , c.job_id
        , c.closed_at
        , c.job_created_at
        , c.job_category
        , c.queue_slug
        , c.queue_is_multi_review
        , c.closure_decision_count                               as decisions_on_job
        , c.first_seen_at
        , c.delivery_count
        , c.was_redelivered
        , c.record_source

        , d.index::number                                        as decision_ordinal
        , {{ cinder_event_timestamp('d.value:timestamp') }}       as decided_at

        -- Coarse origin. `manual` is the only value that implies a human; everything else
        -- is machine-driven.
        , d.value:source:type::varchar                            as decision_source_type

        -- The reviewer, when the decision was made by a person. Absent on automated
        -- decisions, so per-moderator metrics must exclude rather than bucket these.
        , d.value:source:user:name::varchar                       as reviewer_name
        , d.value:source:user:email::varchar                      as reviewer_email
        , d.value:source:user:groups                              as reviewer_groups

        -- The entity as it was at decision time. Usually the job's entity, but taken from
        -- the decision rather than the job so a decision on a different entity is not
        -- silently reattributed. Falls back to the job's entity when absent.
        , coalesce(d.value:entity:entity_schema::varchar, c.job_entity_schema)
                                                                  as entity_schema
        , coalesce(d.value:entity:attributes:id::varchar, c.job_entity_id)
                                                                  as entity_id
        , d.value:entity:attributes                               as entity_attributes

        , d.value:policies                                        as policies
        , d.value:enforcement_actions                             as enforcement_actions
        , d.value:notes::varchar                                  as notes

    from closures c
    , lateral flatten(input => c.closure_decisions) d

),

derived as (

    select
          *

        , array_size(coalesce(policies, array_construct()))       as policy_count
        , array_size(coalesce(enforcement_actions, array_construct()))
                                                                  as enforcement_action_count

        , decision_source_type = 'manual'                         as is_human_decision
        , decision_source_type is distinct from 'manual'           as is_automated

        -- Handle time. Job creation to decision, which is the measure the moderation team
        -- means by "handle time" when comparing queues and moderators.
        --
        -- Null rather than zero when creation time is missing: a fabricated zero would
        -- read as instant resolution and flatter every average it lands in.
        , case
              when job_created_at is not null and decided_at is not null
              then datediff('second', job_created_at, decided_at)
          end                                                     as handle_time_seconds

        , notes is not null and length(trim(notes)) > 0            as has_notes

        -- Whether any applied policy is a real violation. A decision carrying only
        -- non-violating policies is a reviewed-and-cleared outcome; counting it as
        -- enforcement is one of the easiest ways to overstate the numbers.
        , coalesce(
              array_size(
                  filter(policies, p -> p:is_non_violating::boolean = false)
              ) > 0,
              false
          )                                                       as is_violating_outcome

        , coalesce(
              array_size(
                  filter(policies, p -> p:is_illegal::boolean = true)
              ) > 0,
              false
          )                                                       as is_illegal_outcome

    from exploded

)

select
      {{ cinder_surrogate_key(['job_closure_event_sk', 'decision_ordinal']) }}
                                                                  as decision_sk
    , job_closure_event_sk
    , decision_ordinal
    , job_id
    , decided_at
    , closed_at
    , job_created_at
    , handle_time_seconds
    , job_category
    , queue_slug
    , queue_is_multi_review
    , decision_source_type
    , is_human_decision
    , is_automated
    , reviewer_name
    , reviewer_email
    , reviewer_groups
    , entity_schema
    , entity_id
    , entity_attributes
    , policies
    , policy_count
    , enforcement_actions
    , enforcement_action_count
    , notes
    , has_notes
    , is_violating_outcome
    , is_illegal_outcome
    , decisions_on_job

    -- True when this was the last decision before the job closed. For a multi-review job
    -- the earlier decisions are the individual reviews and the last is the resolution, so
    -- "one decision per closed job" means filtering on this.
    , decision_ordinal = decisions_on_job - 1                     as is_final_decision

    , first_seen_at
    , delivery_count
    , was_redelivered
    , record_source
from derived
