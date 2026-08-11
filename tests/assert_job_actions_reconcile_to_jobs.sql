/*
    Action counts on the job fact must match the action fact.

    fct_jobs aggregates job actions to job grain. If those aggregates drift from the action
    fact, the accumulating snapshot has gone stale or a join has fanned out — and every
    lifecycle measure built on it, including "queue changes before closure", becomes wrong
    while still looking entirely reasonable.

    An aggregate that silently disagrees with its own source is the most dangerous kind of
    defect in a dimensional model, because nothing about the output looks broken.
*/

with from_actions as (

    select
          job_id
        , count(*)                              as action_count
        , count_if(action = 'changed_queue')    as queue_change_count
    from {{ ref('fct_job_actions') }}
    group by job_id

),

from_jobs as (

    select
          job_id
        , action_count
        , queue_change_count
    from {{ ref('fct_jobs') }}
    where has_action_history

)

select
      coalesce(a.job_id, j.job_id)  as job_id
    , a.action_count                as action_fact_actions
    , j.action_count                as job_fact_actions
    , a.queue_change_count          as action_fact_queue_changes
    , j.queue_change_count          as job_fact_queue_changes
from from_actions a
full outer join from_jobs j
    on a.job_id = j.job_id
where a.job_id is null
   or j.job_id is null
   or a.action_count is distinct from j.action_count
   or a.queue_change_count is distinct from j.queue_change_count
