{{ config(severity='warn') }}

/*
    Every closure should carry at least one decision.

    Cinder does not send `job.closed` for a job that closes with zero production decisions,
    so a closure payload with an empty decisions array should not exist. If one appears, the
    documented behaviour has changed and every decision-grain metric in this project — all
    of which are sourced from that array — needs re-examining.

    This is the canary for the project's central assumption, which is why it is here as an
    explicit test rather than left implicit.
*/

select
      job_closure_event_sk
    , job_id
    , closed_at
    , closure_decision_count
from {{ ref('stg_cinder__job_closures') }}
where coalesce(closure_decision_count, 0) = 0
