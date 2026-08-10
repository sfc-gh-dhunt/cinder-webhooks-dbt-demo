/*
    Every decision must belong to a closure that exists.

    Decisions are extracted from inside closure payloads, so an orphan is structurally
    impossible — which is exactly why it is worth asserting. If this ever fails, the
    extraction logic has broken rather than the source data, and the failure would otherwise
    show up as quietly missing rows rather than as an error.
*/

select
      d.decision_sk
    , d.job_closure_event_sk
    , d.job_id
from {{ ref('stg_cinder__decisions') }} d
left join {{ ref('stg_cinder__job_closures') }} c
    on d.job_closure_event_sk = c.job_closure_event_sk
where c.job_closure_event_sk is null
