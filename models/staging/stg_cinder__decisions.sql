/*
    One row per decision delivery.

    THE DECISION GRAIN LIVES HERE. `job.closed` also carries decisions, in its
    `decisions` array, and modelling both as facts would double-count every decision on
    any job that closed. This model is authoritative; the closure array is treated as
    closure context only (see stg_cinder__job_closure_decisions).

    Nested arrays are not flattened here. Each gets its own model at its own grain:
    policies, enforcement actions, classifier predictions, point updates, appeals. That
    keeps this model at exactly one row per decision, which is what makes it safe to
    join to.
*/

with base as (

    select * from {{ ref('base_cinder__decision_created') }}

),

flattened as (

    select
          event_sk                                              as decision_event_sk

        -- ---- Identity -------------------------------------------------------------
        , payload:source:decision:id::varchar                   as decision_id
        , payload:source:decision:type::varchar                 as decision_type

        -- ---- Event time -----------------------------------------------------------
        -- Payload timestamp, timezone-aware. Never first_seen_at, which is when the
        -- ingestion layer happened to receive the delivery.
        , {{ cinder_event_timestamp('payload:timestamp') }}     as decided_at

        -- ---- Job context ----------------------------------------------------------
        , payload:source:job:id::varchar                        as job_id
        , {{ cinder_event_timestamp('payload:source:job:created_at') }} as job_created_at
        , payload:source:job:queue:slug::varchar                as queue_slug
        , payload:source:job:queue:is_multi_review::boolean     as queue_is_multi_review

        -- ---- Entity under review --------------------------------------------------
        -- entity_attributes stays a VARIANT on purpose. The keys vary by entity_schema:
        -- a `user` carries email and username, a `text_post` carries caption and
        -- object_url, and a customer-defined schema carries whatever they defined.
        -- Flattening this to fixed columns would break on the first new schema and would
        -- silently drop attributes in the meantime.
        , payload:entity:entity_schema::varchar                 as entity_schema
        , payload:entity:attributes:id::varchar                 as entity_id
        , payload:entity:attributes                             as entity_attributes
        , payload:entity:predictions                            as entity_predictions

        -- ---- Who decided ----------------------------------------------------------
        -- Absent for automated decisions. Null here means "no human", not "unknown
        -- human", and anything computing reviewer productivity must exclude rather than
        -- bucket these.
        , payload:source:user:name::varchar                     as reviewer_name
        , payload:source:user:email::varchar                    as reviewer_email
        , payload:source:user:groups                            as reviewer_groups

        -- ---- Outcome --------------------------------------------------------------
        , payload:policies                                      as policies
        , payload:policies_removed                              as policies_removed
        , payload:enforcement_actions                           as enforcement_actions
        , payload:enforcement_actions_removed                   as enforcement_actions_removed
        , payload:point_updates                                 as point_updates
        , payload:source:decision:metadata                      as decision_metadata

        -- An empty string is a real value here: the reviewer left the note blank.
        -- Distinguishing that from a missing key is worth doing, because "no reviewers
        -- write notes" and "we do not capture notes" are different problems.
        , payload:notes::varchar                                as notes

        -- ---- Multi-review ---------------------------------------------------------
        -- Present only on the final decision of a multi-review job; Cinder sends no
        -- webhook for the intermediate ones. So a multi-review job yields exactly one
        -- decision row, with the earlier reviews recorded inside resolution_path.
        , payload:resolution:resolution_type::varchar           as resolution_type
        , payload:resolution:resolution_path                    as resolution_path

        -- ---- Appeals --------------------------------------------------------------
        -- A non-empty array means this decision resolved one or more appeals. The
        -- documented, future-proof way to detect an appeal outcome — the legacy
        -- appeal-specific decision types (override / confirm / revert) and the
        -- deprecated `appeal` field are both avoided here.
        , payload:appeals_resolved                              as appeals_resolved

        -- ---- Override chain -------------------------------------------------------
        , payload:previous_decision                             as previous_decision

        -- ---- Delivery lineage -----------------------------------------------------
        , first_seen_at
        , delivery_count
        , was_redelivered
        , record_source

    from base

),

derived as (

    select
          *

        -- Human or machine. The distinction drives the automation-rate metric and is not
        -- inferable from the presence of a user alone, because some human-originated
        -- types (bulk_action, api_decision) carry no user object.
        , case
              when decision_type in (
                    'automated', 'cinder_workflow', 'agent', 'bulk_action', 'api_decision'
              ) then 'automated'
              else 'human'
          end                                                   as decision_actor_type

        , array_size(coalesce(policies, array_construct()))     as policy_count
        , array_size(coalesce(enforcement_actions, array_construct()))
                                                                as enforcement_action_count
        , array_size(coalesce(policies_removed, array_construct()))
                                                                as policy_removed_count
        , array_size(coalesce(appeals_resolved, array_construct()))
                                                                as appeal_resolved_count
        , array_size(coalesce(resolution_path, array_construct()))
                                                                as prior_review_count

        , resolution_type is not null                           as is_multi_review_resolution
        , array_size(coalesce(appeals_resolved, array_construct())) > 0
                                                                as resolves_appeal
        , previous_decision is not null                         as is_override

        -- Depth of the override chain. Measured to five levels, which is well past
        -- anything observed; a deeper chain reports as 5 rather than silently as 1.
        -- Snowflake has no recursive VARIANT walk, so this is explicit by design.
        , case
              when previous_decision is null then 0
              when previous_decision:previous_decision is null then 1
              when previous_decision:previous_decision:previous_decision is null then 2
              when previous_decision:previous_decision:previous_decision:previous_decision is null then 3
              when previous_decision:previous_decision:previous_decision:previous_decision:previous_decision is null then 4
              else 5
          end                                                   as override_chain_depth

        -- Latency from job creation to decision. Null when job_created_at is absent
        -- rather than defaulting to zero, because a fabricated zero would drag every
        -- average down and look like excellent performance.
        , case
              when job_created_at is not null and decided_at is not null
              then datediff('second', job_created_at, decided_at)
          end                                                   as decision_latency_seconds

        , notes is not null and length(trim(notes)) > 0          as has_notes

    from flattened

)

select
      decision_event_sk
    , decision_id
    , decision_type
    , decision_actor_type
    , decided_at
    , job_id
    , job_created_at
    , decision_latency_seconds
    , queue_slug
    , queue_is_multi_review
    , entity_schema
    , entity_id
    , entity_attributes
    , entity_predictions
    , reviewer_name
    , reviewer_email
    , reviewer_groups
    , policies
    , policies_removed
    , enforcement_actions
    , enforcement_actions_removed
    , point_updates
    , decision_metadata
    , notes
    , has_notes
    , policy_count
    , policy_removed_count
    , enforcement_action_count
    , resolution_type
    , resolution_path
    , prior_review_count
    , is_multi_review_resolution
    , appeals_resolved
    , appeal_resolved_count
    , resolves_appeal
    , previous_decision
    , is_override
    , override_chain_depth
    , first_seen_at
    , delivery_count
    , was_redelivered
    , record_source
from derived
