{{
    config(
        materialized='incremental',
        unique_key='decision_sk',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

/*
    Decision fact — one row per decision recorded on a closed job.

    Sourced from the `decisions` array inside `job.closed`, which is the only decision
    surface in scope. See stg_cinder__decisions for what that costs and what it gives.

    This is the fact for the questions moderation leads actually ask: handle time by queue
    and by moderator, share of decisions taken automatically, enforcement volume, policy
    distribution (via fct_decision_policies).

    Incremental, keyed on the decision surrogate key and watermarked on INGESTION time
    rather than event time. Event time is the wrong watermark for a webhook feed: a
    redelivery or a late subscription can bring in an event timestamped earlier than
    anything already loaded, and an event-time watermark would skip it silently.

    Merge rather than append, so a redelivered closure updates its decisions in place
    instead of duplicating them.

    If you change this model's incremental logic, rebuild with --full-refresh. A normal
    incremental run only touches new rows and leaves data built by the old logic in place,
    looking correct.
*/

with decisions as (

    select * from {{ ref('stg_cinder__decisions') }}

    {% if is_incremental() %}
    -- The 3-hour overlap absorbs late deliveries and clock skew between the ingestion
    -- runtime and Snowflake; the merge on decision_sk makes reprocessing it idempotent.
    where first_seen_at >= (
        select coalesce(
                   dateadd('hour', -3, max(existing.first_seen_at)),
                   '1900-01-01'::timestamp_ntz
               )
        from {{ this }} existing
    )
    {% endif %}

),

-- Aggregated to decision grain before joining, so neither can fan the fact out.
enforcement_summary as (

    select
          e.decision_sk
        , count_if(not e.is_no_action)                              as enforcement_action_count
        , count_if(e.is_no_action)                                  as no_action_count
        , max(a.enforcement_severity_rank)                          as max_enforcement_severity_rank
        , max(case when a.enforcement_severity_rank = 5 then 1 else 0 end) = 1
                                                                    as included_account_ban
    from {{ ref('stg_cinder__decision_enforcement_actions') }} e
    left join {{ ref('dim_enforcement_action') }} a
        on e.enforcement_action_slug = a.enforcement_action_slug
    group by e.decision_sk

),

policy_summary as (

    select
          p.decision_sk
        , count(*)                                                  as policy_count
        , count_if(p.policy_is_illegal)                             as illegal_policy_count
        , count_if(p.policy_is_non_violating)                       as non_violating_policy_count
        , count(distinct coalesce(p.policy_parent_id, p.policy_id))  as distinct_policy_group_count
        -- A readable label for the decision's primary policy area, so the fact is useful
        -- on its own without joining out to the policy grain.
        , max(case when p.is_primary_policy then d.policy_group_name end)
                                                                    as primary_policy_group_name
        , max(case when p.is_primary_policy then p.policy_name end)  as primary_policy_name
    from {{ ref('stg_cinder__decision_policies') }} p
    left join {{ ref('dim_policy') }} d
        on p.policy_id = d.policy_id
    group by p.decision_sk

)

select
    -- ---- Keys ---------------------------------------------------------------------
      d.decision_sk
    , d.job_closure_event_sk

    , q.queue_key
    , r.reviewer_key            -- null for automated decisions, by design
    , e.entity_key

    -- ---- Event time ---------------------------------------------------------------
    , d.decided_at
    , d.decided_at::date                                        as decided_date
    , date_trunc('week', d.decided_at)::date                    as decided_week
    , date_trunc('month', d.decided_at)::date                   as decided_month
    , dayname(d.decided_at)                                     as decided_day_of_week
    , hour(d.decided_at)                                        as decided_hour_of_day

    -- ---- Degenerate dimensions ----------------------------------------------------
    , d.job_id
    , d.job_created_at
    , d.closed_at
    , d.job_category
    , d.queue_slug
    , d.queue_is_multi_review
    , d.decision_source_type
    , d.entity_schema
    , d.entity_id
    , d.reviewer_email
    , d.decision_ordinal

    -- Staffing attribution that covers every decision, not just the human ones.
    --
    -- Automated decisions carry no reviewer, so joining to dim_reviewer leaves the staffing
    -- model null — and a breakdown by staffing model then has an unlabelled bucket holding a
    -- third of the volume. Labelling it here rather than inside dim_reviewer keeps the
    -- dimension honest: 'Automated' is a property of the decision, not of a reviewer who does
    -- not exist.
    , coalesce(r.staffing_model, 'Automated')                   as staffing_model

    , ps.primary_policy_name
    , ps.primary_policy_group_name

    -- ---- Measures -----------------------------------------------------------------
    , 1                                                         as decision_count

    -- Handle time: job creation to decision. The measure meant by "handle time" when
    -- comparing queues, moderators and entity types.
    , d.handle_time_seconds
    , d.handle_time_seconds / 60.0                              as handle_time_minutes
    , d.handle_time_seconds / 3600.0                            as handle_time_hours

    , coalesce(ps.policy_count, 0)                              as policy_count
    , coalesce(ps.illegal_policy_count, 0)                      as illegal_policy_count
    , coalesce(ps.non_violating_policy_count, 0)                as non_violating_policy_count
    , coalesce(ps.distinct_policy_group_count, 0)               as distinct_policy_group_count

    , coalesce(es.enforcement_action_count, 0)                  as enforcement_action_count
    , coalesce(es.no_action_count, 0)                           as no_action_count
    , es.max_enforcement_severity_rank
    , coalesce(es.included_account_ban, false)                  as included_account_ban

    , d.decisions_on_job

    -- ---- Flags --------------------------------------------------------------------
    , d.is_human_decision
    , d.is_automated
    , d.is_violating_outcome
    , d.is_illegal_outcome

    -- A cleared outcome: policies were applied but all of them are non-violating. This is
    -- "we looked and it was fine", and counting it as enforcement overstates the numbers.
    , coalesce(ps.policy_count, 0) > 0
      and coalesce(ps.non_violating_policy_count, 0) = coalesce(ps.policy_count, 0)
                                                                as is_cleared_outcome

    , d.is_final_decision
    , d.queue_is_multi_review and d.decisions_on_job > 1        as is_multi_review_decision
    , d.has_notes

    -- ---- Delivery lineage ---------------------------------------------------------
    , d.first_seen_at
    , d.delivery_count
    , d.was_redelivered
    , d.record_source

from decisions d
-- LEFT joins throughout. An inner join to a dimension would silently drop facts whenever a
-- dimension row is missing, which is exactly when you most want to see the row.
left join {{ ref('dim_queue') }} q
    on d.queue_slug = q.queue_slug
left join {{ ref('dim_reviewer') }} r
    on lower(trim(d.reviewer_email)) = r.reviewer_email
left join {{ ref('dim_entity') }} e
    on  d.entity_schema = e.entity_schema
    and d.entity_id = e.entity_id
left join enforcement_summary es
    on d.decision_sk = es.decision_sk
left join policy_summary ps
    on d.decision_sk = ps.decision_sk
