{{
    config(
        materialized='incremental',
        unique_key='decision_policy_sk',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

/*
    Decision-policy fact — one row per decision per applied policy.

    The grain for policy distribution, which is one of the questions asked most often and
    got wrong most often.

    IT EXISTS AS A SEPARATE FACT for a specific reason: a decision can apply several
    policies. Joining fct_decisions to a policy bridge would fan the decision rows out and
    inflate every decision-level measure — handle time averages included. Keeping the two
    apart means `decision_count` is only ever summed from fct_decisions, and policy volume
    is only ever summed from here.

    Two ways to count, and the choice is not cosmetic:

      * `policy_application_count` — raw volume. Sums to more than the decision count on
        any multi-policy decision. Use it for "how often is this policy applied".
      * `decision_count_allocated` — fractional. Sums back to the true decision count. Use
        it when a distribution has to add up to total decisions.

    Policy hierarchy is carried through, so distribution can be reported at leaf level or
    rolled up to the parent policy area. Rolled up is almost always the readable one.
*/

with decision_policies as (

    select * from {{ ref('stg_cinder__decision_policies') }}

    {% if is_incremental() %}
    where decision_sk in (
        select decision_sk
        from {{ ref('stg_cinder__decisions') }}
        where first_seen_at >= (
            select coalesce(
                       dateadd('hour', -3, max(f.decided_at)),
                       '1900-01-01'::timestamp_ntz
                   )::timestamp_ntz
            from {{ this }} f
        )
    )
    {% endif %}

)

select
    -- ---- Keys ---------------------------------------------------------------------
      dp.decision_policy_sk
    , dp.decision_sk
    , dp.job_closure_event_sk

    , p.policy_key
    , q.queue_key
    , r.reviewer_key
    , e.entity_key

    -- ---- Event time ---------------------------------------------------------------
    , dp.decided_at
    , dp.decided_at::date                                       as decided_date
    , date_trunc('week', dp.decided_at)::date                   as decided_week
    , date_trunc('month', dp.decided_at)::date                  as decided_month

    -- ---- Degenerate dimensions ----------------------------------------------------
    , dp.policy_id
    , dp.policy_name
    , dp.policy_parent_id
    , p.policy_parent_name
    , p.policy_group_name
    , p.policy_severity_class
    , dp.is_root_policy
    , dp.policy_is_illegal
    , dp.policy_is_non_violating
    , dp.job_id
    , dp.job_category
    , dp.queue_slug
    , dp.entity_schema
    , dp.entity_id
    , dp.decision_source_type
    , dp.reviewer_email
    , dp.policy_ordinal
    , dp.is_primary_policy

    -- ---- Measures -----------------------------------------------------------------
    , 1                                                         as policy_application_count
    , dp.decision_count_allocated
    , dp.policies_on_decision
    , dp.policy_enforcement_action_count
    , dp.handle_time_seconds
    , dp.handle_time_seconds / 3600.0                           as handle_time_hours

    -- ---- Flags --------------------------------------------------------------------
    , dp.is_automated
    , dp.is_human_decision

from decision_policies dp
left join {{ ref('dim_policy') }} p
    on dp.policy_id = p.policy_id
left join {{ ref('dim_queue') }} q
    on dp.queue_slug = q.queue_slug
left join {{ ref('dim_reviewer') }} r
    on lower(trim(dp.reviewer_email)) = r.reviewer_email
left join {{ ref('dim_entity') }} e
    on  dp.entity_schema = e.entity_schema
    and dp.entity_id = e.entity_id
