{{ config(materialized='ephemeral') }}

/*
    Base layer for job.closed.

    Resolve source (seeds / raw / both), key each delivery, deduplicate, and surface the
    redelivery evidence. No payload interpretation happens here — see the staging models.

    The body is shared by all three base models: macros/cinder_base_event_model.sql
*/

{{ cinder_base_event_model('job_closed') }}
