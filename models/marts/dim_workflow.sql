/*
    Conformed workflow dimension.

    Only `job.actioned` exposes workflow identity, and only when a workflow took the
    action. Automated decisions on `decision.created` do not name the workflow that made
    them — the decision type says `cinder_workflow` or `automated`, but the specific
    workflow is not in the payload. So this dimension covers workflow-driven job actions
    and cannot be joined to automated decisions.

    That asymmetry is a property of the webhook surface, not an oversight here, and it is
    worth knowing before someone promises a "decisions by workflow" breakdown.

    Rule name and workflow name are point-in-time in the payload — Cinder sends the name as
    at the action. The latest observation wins here, so a renamed workflow shows its current
    name and its whole history follows it.
*/

with workflow_fragments as (

    select
          actor_workflow_id                 as workflow_id
        , actor_workflow_name               as workflow_name
        , actor_workflow_rule_id            as workflow_rule_id
        , actor_workflow_rule_name          as workflow_rule_name
        , actor_workflow_trigger_type       as workflow_trigger_type
        , actor_workflow_event_name         as workflow_event_name
        , actioned_at                       as observed_at
    from {{ ref('stg_cinder__job_actions') }}
    where actor_workflow_id is not null

),

aggregated as (

    select
          workflow_id
        , min(observed_at)                          as first_seen_at
        , max(observed_at)                          as last_seen_at
        , count(*)                                  as action_count
        , count(distinct workflow_rule_id)          as distinct_rule_count
        , count(distinct workflow_event_name)       as distinct_event_name_count
    from workflow_fragments
    group by workflow_id

),

latest_attributes as (

    select
          workflow_id
        , workflow_name
        , workflow_rule_id
        , workflow_rule_name
        , workflow_trigger_type
    from workflow_fragments
    qualify row_number() over (
        partition by workflow_id
        order by observed_at desc nulls last
    ) = 1

)

select
      {{ dbt_utils.generate_surrogate_key(['a.workflow_id']) }}   as workflow_key
    , a.workflow_id
    , l.workflow_name

    -- The most recent rule to fire, not the only one: a workflow can hold many rules, and
    -- distinct_rule_count tells you whether this is the whole story.
    , l.workflow_rule_id
    , l.workflow_rule_name
    , l.workflow_trigger_type

    , a.action_count
    , a.distinct_rule_count
    , a.distinct_event_name_count
    , a.first_seen_at
    , a.last_seen_at
from aggregated a
inner join latest_attributes l
    on a.workflow_id = l.workflow_id
