{{ config(severity='warn') }}

/*
    A job cannot be decided before it was created.

    This is the test that catches a timezone error, and it catches it in a way a range check
    never would. Both timestamps are individually plausible; it is only their ORDER that
    reveals the bug. An offset dropped on one field and kept on the other produces negative
    handle times, which then silently deflate every average handle time they land in.

    Warning rather than error: a small negative value is explicable as clock skew between
    Cinder components. A large or frequent one is not, which is why the magnitude is returned
    rather than just the row.
*/

select
      decision_sk
    , job_id
    , job_created_at
    , decided_at
    , datediff('second', job_created_at, decided_at) as handle_time_seconds
from {{ ref('stg_cinder__decisions') }}
where job_created_at is not null
  and decided_at is not null
  and decided_at < job_created_at
