{{
    config(
        materialized='table'
    )
}}

/*
    Job fact — one row per job, whether or not it has closed.

    An ACCUMULATING SNAPSHOT: the row for a job is rewritten as its lifecycle progresses.
    That is the classic pattern for a process with a defined start and end and a variable
    number of steps in between, and it is what makes the cross-event questions answerable:

      * How many queue changes does a job undergo before it closes?
      * What is the median age of a job that has been actioned?
      * What is the median time to close, by queue or entity type?
      * What share of jobs are closed by an automated decision?
      * Do some moderators have a best queue in terms of handle time?

    None of those can be answered from either event alone. Job actions know the movement
    history but not the outcome; closures know the outcome but not the movement history.

    WHY THIS IS A FULL-REFRESH TABLE AND NOT INCREMENTAL. An accumulating snapshot mutates
    rows that already exist — a new action on a three-week-old job changes that job's row.
    An incremental build would have to re-derive every job touched anywhere in the window,
    which is possible but is a well-known source of subtly stale rows when the window is
    even slightly too narrow. At this scale a full rebuild is cheap and always correct. If
    volume makes that untenable, the right change is to re-derive by job id for jobs with
    any new event, not to narrow the window.

    THE JOB UNIVERSE IS THE UNION OF BOTH EVENTS. A job can appear in the action history and
    never close (still open, or closed without a decision so no closure event was sent), or
    appear as a closure with no action history (the subscription started after its actions).
    Both are real and both are represented, flagged rather than silently dropped.
*/

with actions as (

    select * from {{ ref('stg_cinder__job_actions') }}

),

closures as (

    select * from {{ ref('stg_cinder__job_closures') }}

),

decisions as (

    select * from {{ ref('fct_decisions') }}

),

-- Every job referenced by either event.
job_universe as (

    -- UNION DISTINCT, not UNION ALL. This is a key list, so collapsing duplicates is the
    -- entire point — a job appearing on both events must yield one row, not two. Spelled out
    -- rather than left as a bare UNION, because a reader should not have to know which of the
    -- two a bare UNION means.
    select job_id
    from actions
    where job_id is not null

    union distinct

    select job_id
    from closures
    where job_id is not null

),

action_summary as (

    select
          job_id
        , count(*)                                              as action_count
        , count_if(action = 'created')                          as create_action_count
        , count_if(action = 'changed_queue')                    as queue_change_count
        , count_if(action = 'escalated')                        as escalation_count
        , count_if(action = 'cancelled')                        as cancellation_count
        , count_if(action = 'skipped')                          as skip_count
        , count_if(action = 'deferred')                         as defer_count
        , count_if(action = 'assigned')                         as assignment_count
        , count_if(actor_type = 'workflow')                     as workflow_action_count
        , count_if(actor_type = 'user')                         as human_action_count
        , count_if(actor_type = 'none')                          as system_action_count
        , count_if(action_source = 'workflow' and action = 'cancelled')
                                                                as workflow_cancellation_count
        , count(distinct actor_user_email)                      as distinct_actor_count
        , count(distinct queue_slug)                            as distinct_queue_count
        , min(actioned_at)                                      as first_actioned_at
        , max(actioned_at)                                      as last_actioned_at
        , min(job_created_at)                                   as job_created_at_from_actions
        , max(job_num_reports)                                  as max_reports_on_job
        , max(job_priority)                                     as max_priority
    from actions
    group by job_id

),

-- Latest action determines the job's current queue and status. Job actions record
-- movements, not state, so current state has to be reconstructed by ordering them — there
-- is no job-state table in the webhook surface.
latest_action as (

    select
          job_id
        , queue_slug            as current_queue_slug
        , job_status_after      as latest_action_status
        , job_category          as latest_action_job_category
        , entity_schema         as action_entity_schema
        , entity_id             as action_entity_id
        , action                as latest_action
        , actioned_at           as latest_actioned_at
    from actions
    qualify row_number() over (
        partition by job_id
        order by actioned_at desc nulls last
    ) = 1

),

closure_summary as (

    select
          job_id
        , max(job_closure_event_sk)                             as job_closure_event_sk
        , min(closed_at)                                        as closed_at
        , min(job_created_at)                                   as job_created_at_from_closure
        , max(job_category)                                     as closure_job_category
        , max(queue_slug)                                       as closure_queue_slug
        , max(queue_is_multi_review)                            as queue_is_multi_review
        , max(entity_schema)                                    as closure_entity_schema
        , max(entity_id)                                        as closure_entity_id
    from closures
    group by job_id

),

decision_summary as (

    select
          job_id
        , count(*)                                              as decision_count
        , count_if(is_automated)                                as automated_decision_count
        , count_if(is_human_decision)                           as human_decision_count
        , count(distinct reviewer_email)                        as distinct_reviewer_count
        , sum(enforcement_action_count)                         as enforcement_action_count
        , max(max_enforcement_severity_rank)                    as max_enforcement_severity_rank
        , count_if(is_violating_outcome)                        as violating_decision_count
        , count_if(is_illegal_outcome)                          as illegal_decision_count
        , count_if(is_cleared_outcome)                          as cleared_decision_count
        , min(decided_at)                                       as first_decided_at
        , max(decided_at)                                       as last_decided_at
        , max(handle_time_seconds)                              as handle_time_seconds
        , max(case when is_final_decision then reviewer_email end)
                                                                as final_reviewer_email
        , max(case when is_final_decision then decision_source_type end)
                                                                as final_decision_source_type
        , max(case when is_final_decision then primary_policy_group_name end)
                                                                as final_policy_group_name
        , max(case when is_final_decision and is_automated then 1 else 0 end) = 1
                                                                as closed_by_automated_decision
    from decisions
    group by job_id

),

assembled as (

    select
          u.job_id

        -- Creation time from whichever event carries it. Both do in practice; the closure
        -- is preferred because it is the more reliably populated of the two.
        , coalesce(cs.job_created_at_from_closure, a.job_created_at_from_actions)
                                                                as job_created_at

        , cs.closed_at
        , cs.job_closure_event_sk

        -- Category and queue: the closure is authoritative once a job has closed, because
        -- it reflects where the job ended up. Before that, the latest action is all there is.
        , coalesce(cs.closure_job_category, la.latest_action_job_category)
                                                                as job_category
        , coalesce(cs.closure_queue_slug, la.current_queue_slug) as final_queue_slug
        , la.current_queue_slug
        , cs.queue_is_multi_review
        , la.latest_action
        , la.latest_actioned_at
        , la.latest_action_status

        , coalesce(cs.closure_entity_schema, la.action_entity_schema)
                                                                as entity_schema
        , coalesce(cs.closure_entity_id, la.action_entity_id)     as entity_id

        -- Action measures
        , coalesce(a.action_count, 0)                            as action_count
        , coalesce(a.queue_change_count, 0)                      as queue_change_count
        , coalesce(a.escalation_count, 0)                         as escalation_count
        , coalesce(a.cancellation_count, 0)                       as cancellation_count
        , coalesce(a.workflow_cancellation_count, 0)              as workflow_cancellation_count
        , coalesce(a.skip_count, 0)                               as skip_count
        , coalesce(a.defer_count, 0)                              as defer_count
        , coalesce(a.assignment_count, 0)                         as assignment_count
        , coalesce(a.workflow_action_count, 0)                    as workflow_action_count
        , coalesce(a.human_action_count, 0)                       as human_action_count
        , coalesce(a.system_action_count, 0)                      as system_action_count
        , a.distinct_actor_count
        , a.distinct_queue_count
        , a.first_actioned_at
        , a.last_actioned_at
        , a.max_reports_on_job
        , a.max_priority

        -- Decision measures
        , coalesce(d.decision_count, 0)                           as decision_count
        , coalesce(d.automated_decision_count, 0)                 as automated_decision_count
        , coalesce(d.human_decision_count, 0)                     as human_decision_count
        , d.distinct_reviewer_count
        , coalesce(d.enforcement_action_count, 0)                 as enforcement_action_count
        , d.max_enforcement_severity_rank
        , coalesce(d.violating_decision_count, 0)                 as violating_decision_count
        , coalesce(d.illegal_decision_count, 0)                   as illegal_decision_count
        , coalesce(d.cleared_decision_count, 0)                   as cleared_decision_count
        , d.first_decided_at
        , d.last_decided_at
        , d.handle_time_seconds
        , d.final_reviewer_email
        , d.final_decision_source_type
        , d.final_policy_group_name
        , coalesce(d.closed_by_automated_decision, false)         as closed_by_automated_decision

        -- Presence flags
        , a.job_id is not null                                    as has_action_history
        , cs.job_id is not null                                   as has_closure

    from job_universe u
    left join action_summary a      on u.job_id = a.job_id
    left join latest_action la      on u.job_id = la.job_id
    left join closure_summary cs    on u.job_id = cs.job_id
    left join decision_summary d    on u.job_id = d.job_id

)

select
    -- ---- Keys ---------------------------------------------------------------------
      {{ cinder_surrogate_key(['s.job_id']) }}         as job_key
    , s.job_id
    , s.job_closure_event_sk

    , q.queue_key                                                 as final_queue_key
    , e.entity_key
    , r.reviewer_key                                              as final_reviewer_key

    -- ---- Lifecycle timestamps -----------------------------------------------------
    , s.job_created_at
    , s.job_created_at::date                                      as created_date
    , date_trunc('month', s.job_created_at)::date                  as created_month
    , s.first_actioned_at
    , s.first_decided_at
    , s.last_decided_at
    , s.last_actioned_at
    , s.closed_at
    , s.closed_at::date                                           as closed_date
    , date_trunc('week', s.closed_at)::date                       as closed_week
    , date_trunc('month', s.closed_at)::date                      as closed_month
    , dayname(s.closed_at)                                        as closed_day_of_week

    -- ---- Durations ----------------------------------------------------------------
    -- Each is null rather than zero when its inputs are missing. A fabricated zero would
    -- read as instant resolution and flatter every average it lands in.

    -- Total time to close. The headline cycle-time measure.
    , case when s.job_created_at is not null and s.closed_at is not null
           then datediff('second', s.job_created_at, s.closed_at) end
                                                                  as time_to_close_seconds
    , case when s.job_created_at is not null and s.closed_at is not null
           then datediff('second', s.job_created_at, s.closed_at) / 3600.0 end
                                                                  as time_to_close_hours

    -- Queue waiting time: creation to first action. Distinct from review time, and usually
    -- the larger of the two when a backlog is building.
    , case when s.job_created_at is not null and s.first_actioned_at is not null
           then datediff('second', s.job_created_at, s.first_actioned_at) end
                                                                  as time_to_first_action_seconds

    -- Handle time: creation to decision. What moderation leads mean when they compare
    -- queues and moderators.
    , s.handle_time_seconds
    , s.handle_time_seconds / 3600.0                              as handle_time_hours

    -- Post-decision lag: the call was made, but the job stayed open. A different
    -- operational problem from slow review, and invisible if you only measure time to close.
    , case when s.last_decided_at is not null and s.closed_at is not null
           then datediff('second', s.last_decided_at, s.closed_at) end
                                                                  as decision_to_close_seconds

    -- Age of a still-open job, as at the last time anything happened to it. Null once
    -- closed. Answers "median age of a job that has been actioned" without needing a
    -- current-time reference, which would make the measure non-deterministic.
    , case when s.closed_at is null
                and s.job_created_at is not null
                and s.last_actioned_at is not null
           then datediff('second', s.job_created_at, s.last_actioned_at) end
                                                                  as open_age_at_last_action_secs

    -- ---- Degenerate dimensions ----------------------------------------------------
    , s.job_category
    , s.final_queue_slug
    , s.current_queue_slug
    , s.queue_is_multi_review
    , s.entity_schema
    , s.entity_id
    , s.latest_action
    , s.final_reviewer_email
    , s.final_decision_source_type
    , s.final_policy_group_name

    -- Job state, derived. A job with a closure is closed; otherwise the latest action's
    -- status is the best available answer, and 'unknown' is honest when there is no action
    -- history either.
    , case
          when s.has_closure then 'closed'
          when s.latest_action_status is not null then s.latest_action_status
          else 'unknown'
      end                                                         as job_status

    -- ---- Measures -----------------------------------------------------------------
    , 1                                                           as job_count
    , s.action_count
    , s.queue_change_count
    , s.escalation_count
    , s.cancellation_count
    , s.workflow_cancellation_count
    , s.skip_count
    , s.defer_count
    , s.assignment_count
    , s.workflow_action_count
    , s.human_action_count
    , s.system_action_count
    , s.distinct_actor_count
    , s.distinct_queue_count
    , s.max_reports_on_job
    , s.max_priority
    , s.decision_count
    , s.automated_decision_count
    , s.human_decision_count
    , s.distinct_reviewer_count
    , s.enforcement_action_count
    , s.max_enforcement_severity_rank
    , s.violating_decision_count
    , s.illegal_decision_count
    , s.cleared_decision_count

    -- ---- Flags --------------------------------------------------------------------
    , s.has_closure                                               as is_closed
    , not s.has_closure                                           as is_open
    , s.closed_by_automated_decision
    , s.queue_change_count > 0                                    as was_moved_between_queues
    , s.escalation_count > 0                                      as was_escalated
    , s.cancellation_count > 0                                    as was_cancelled
    , s.workflow_cancellation_count > 0                           as was_cancelled_by_workflow
    , s.violating_decision_count > 0                              as had_violating_outcome
    , s.illegal_decision_count > 0                                as had_illegal_outcome

    -- Data-completeness flags. Both states are expected in production and neither is a
    -- defect: a job can be open (no closure yet), or its action history can predate the
    -- webhook subscription.
    , s.has_action_history
    , not s.has_action_history                                    as missing_action_history

from assembled s
left join {{ ref('dim_queue') }} q
    on s.final_queue_slug = q.queue_slug
left join {{ ref('dim_entity') }} e
    on  s.entity_schema = e.entity_schema
    and s.entity_id = e.entity_id
left join {{ ref('dim_reviewer') }} r
    on lower(trim(s.final_reviewer_email)) = r.reviewer_email
