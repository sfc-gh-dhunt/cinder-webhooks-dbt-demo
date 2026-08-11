/*
    One row per job action delivery.

    A job action is a lifecycle movement — queue change, escalation, skip, defer,
    return, cancel, pause, resume, assign, comment. It is NOT a decision. Cinder does not
    send this event when a decision is made; decisions arrive on `decision.created`.
    Treating job actions as moderation outcomes undercounts decisions to zero.

    Two enum notes worth knowing:

      * The `action` list published in the prose narrative for this event is narrower
        than the one in its schema. The schema enum is used for validation, because
        receiving a value the prose omits is far more likely than the schema being wrong.

      * `job_category` here is a four-value enum. The same concept on `job.closed` is
        called `category` and has six values. Both are normalised to `job_category`
        downstream — see macros/cinder_helpers.sql.
*/

with base as (

    select * from {{ ref('base_cinder__job_actioned') }}

),

flattened as (

    select
          event_sk                                              as job_action_event_sk

        -- ---- What happened --------------------------------------------------------
        , payload:action::varchar                               as action
        , payload:source::varchar                               as action_source
        , {{ cinder_event_timestamp('payload:timestamp') }}     as actioned_at
        , payload:notes::varchar                                as notes

        -- ---- Job context ----------------------------------------------------------
        , payload:job:id::varchar                               as job_id

        -- Carried on this event, though the published schema does not promise it. Job age at
        -- action time depends on it, so it is extracted with a null-tolerant cast rather
        -- than assumed.
        , {{ cinder_event_timestamp('payload:job:created_at') }}  as job_created_at
        , payload:job:queue:slug::varchar                       as queue_slug
        , payload:job:queue:is_multi_review::boolean            as queue_is_multi_review

        -- Status AFTER the action, not before. This model records movements, so a
        -- point-in-time job status has to be reconstructed by ordering these events —
        -- there is no job-state table in the webhook surface.
        , payload:job:status::varchar                            as job_status_after
        , payload:job:priority::number                           as job_priority
        , payload:job:num_reports::number                        as job_num_reports
        , {{ cinder_normalised_job_category('payload:job') }}    as job_category

        -- ---- Entity ---------------------------------------------------------------
        , payload:job:entity:entity_schema::varchar              as entity_schema
        , payload:job:entity:attributes:id::varchar              as entity_id
        , payload:job:entity:attributes                          as entity_attributes

        -- ---- Who or what acted ----------------------------------------------------
        , payload:action_made_by:user:name::varchar               as actor_user_name
        , payload:action_made_by:user:email::varchar              as actor_user_email
        , payload:action_made_by:user:groups                      as actor_user_groups

        , payload:action_made_by:workflow:id::varchar             as actor_workflow_id
        , payload:action_made_by:workflow:name::varchar           as actor_workflow_name
        , payload:action_made_by:workflow:rule:id::varchar        as actor_workflow_rule_id
        , payload:action_made_by:workflow:rule:name::varchar      as actor_workflow_rule_name
        , payload:action_made_by:workflow:trigger_type::varchar   as actor_workflow_trigger_type
        , payload:action_made_by:workflow:event:event_name::varchar
                                                                  as actor_workflow_event_name

        -- The entity that TRIGGERED the workflow, which is not necessarily the entity the
        -- action was taken on. A workflow triggered by a user account can close a job on
        -- one of that user's posts. Conflating the two produces wrong attribution, so
        -- both are kept and named distinctly.
        , payload:action_made_by:workflow:event:entity:entity_schema::varchar
                                                                  as trigger_entity_schema
        , payload:action_made_by:workflow:event:entity:attributes:id::varchar
                                                                  as trigger_entity_id

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

        -- Which of the two actor shapes was present. `auto`, `api` and `agent` sources
        -- carry neither, so 'none' is a legitimate third value rather than a data defect.
        , case
              when actor_user_email is not null then 'user'
              when actor_workflow_id is not null then 'workflow'
              else 'none'
          end                                       as actor_type

        , action in ('escalated')                   as is_escalation
        , action in ('cancelled')                   as is_cancellation
        , notes is not null and length(trim(notes)) > 0 as has_notes

        -- How old the job was when this action was taken. The basis of "median age of a
        -- job that has been actioned". Null when creation time is absent rather than zero —
        -- a fabricated zero would read as an instantly-handled job.
        , case
              when job_created_at is not null and actioned_at is not null
              then datediff('second', job_created_at, actioned_at)
          end                                       as job_age_at_action_seconds

        -- The entity object is sometimes absent from this event entirely. Flagged so a
        -- missing entity is visibly a property of the payload rather than a modelling gap.
        , entity_id is not null                     as has_entity

    from flattened

)

select
      job_action_event_sk
    , action
    , action_source
    , actor_type
    , actioned_at
    , job_id
    , job_created_at
    , job_age_at_action_seconds
    , job_status_after
    , job_category
    , job_priority
    , job_num_reports
    , queue_slug
    , queue_is_multi_review
    , entity_schema
    , entity_id
    , entity_attributes
    , has_entity
    , actor_user_name
    , actor_user_email
    , actor_user_groups
    , actor_workflow_id
    , actor_workflow_name
    , actor_workflow_rule_id
    , actor_workflow_rule_name
    , actor_workflow_trigger_type
    , actor_workflow_event_name
    , trigger_entity_schema
    , trigger_entity_id
    , notes
    , has_notes
    , is_escalation
    , is_cancellation
    , first_seen_at
    , delivery_count
    , was_redelivered
    , record_source
from derived
