{{
    config(
        materialized='incremental',
        unique_key='job_action_event_sk',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

/*
    Job action fact — one row per job lifecycle movement.

    Queue changes, escalations, skips, defers, returns, cancellations, pauses, resumes,
    assignments and comments. NOT decisions — Cinder does not send this event when a
    decision is made.

    This is the fact for operational throughput questions: how much work is being moved
    rather than resolved, how often jobs bounce between queues, how much of the queue
    movement is automated.

    Two actor dimensions, and a row has at most one of them: a human reviewer OR a
    workflow. Actions with source `auto`, `api` or `agent` have neither, so both keys are
    null and `actor_type` is 'none'. That is a real category, not missing data.
*/

with job_actions as (

    select * from {{ ref('stg_cinder__job_actions') }}

    {% if is_incremental() %}
    where first_seen_at >= (
        select coalesce(
                   dateadd('hour', -3, max(existing.first_seen_at)),
                   '1900-01-01'::timestamp_ntz
               )
        from {{ this }} existing
    )
    {% endif %}

)

select
    -- ---- Keys ---------------------------------------------------------------------
      a.job_action_event_sk

    , q.queue_key
    , r.reviewer_key            -- null unless a human took the action
    , w.workflow_key            -- null unless a workflow took the action
    , e.entity_key
    , te.entity_key             as trigger_entity_key

    -- ---- Event time ---------------------------------------------------------------
    , a.actioned_at
    , a.actioned_at::date                                       as actioned_date
    , date_trunc('month', a.actioned_at)::date                  as actioned_month
    , dayname(a.actioned_at)                                    as actioned_day_of_week
    , hour(a.actioned_at)                                       as actioned_hour_of_day

    -- ---- Degenerate dimensions ----------------------------------------------------
    , a.job_id
    , a.job_created_at
    , a.action
    , a.action_source
    , a.actor_type
    , a.job_status_after
    , a.job_category
    , a.job_priority
    , a.queue_slug
    , a.queue_is_multi_review
    , a.entity_schema
    , a.entity_id
    , a.actor_user_email
    , a.actor_workflow_id
    , a.actor_workflow_name
    , a.actor_workflow_rule_name
    , a.actor_workflow_event_name
    , a.trigger_entity_schema
    , a.trigger_entity_id

    -- ---- Measures -----------------------------------------------------------------
    , 1                                                         as job_action_count
    , a.job_num_reports                                         as reports_on_job_at_action

    -- How old the job was when this action was taken. The basis of "median age of a job
    -- that has been actioned", which is asked per action type rather than per job.
    , a.job_age_at_action_seconds
    , a.job_age_at_action_seconds / 3600.0                       as job_age_at_action_hours

    -- ---- Flags --------------------------------------------------------------------
    , a.is_escalation
    , a.is_cancellation
    , a.has_entity
    , a.actor_type = 'workflow'                                 as is_automated
    , a.has_notes

    -- True when a workflow acted on an entity other than the one that triggered it.
    -- Worth measuring: it is where automated enforcement propagates beyond the reported
    -- item, and it is invisible if you only look at the actioned entity.
    , a.trigger_entity_id is not null
      and a.trigger_entity_id is distinct from a.entity_id       as acted_on_other_entity

    -- ---- Delivery lineage ---------------------------------------------------------
    , a.first_seen_at
    , a.delivery_count
    , a.was_redelivered
    , a.record_source

from job_actions a
left join {{ ref('dim_queue') }} q
    on a.queue_slug = q.queue_slug
left join {{ ref('dim_reviewer') }} r
    on lower(trim(a.actor_user_email)) = r.reviewer_email
left join {{ ref('dim_workflow') }} w
    on a.actor_workflow_id = w.workflow_id
left join {{ ref('dim_entity') }} e
    on  a.entity_schema = e.entity_schema
    and a.entity_id = e.entity_id
left join {{ ref('dim_entity') }} te
    on  a.trigger_entity_schema = te.entity_schema
    and a.trigger_entity_id = te.entity_id
