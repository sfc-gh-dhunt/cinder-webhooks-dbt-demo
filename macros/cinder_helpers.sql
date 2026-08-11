{#-
    ==================================================================================
    cinder_event_sk
    ==================================================================================
    Surrogate key for a webhook delivery, used to deduplicate.

    THIS IS A DESIGN DECISION, NOT A DOCUMENTED GUARANTEE.

    Cinder's webhooks carry no delivery identifier. The idempotency documentation covers
    inbound API requests to Cinder (via an Idempotency-Key header), not outbound webhook
    deliveries. Some event payloads carry no ID field at all.

    So there is nothing to deduplicate on, and one has to be synthesised. This macro
    hashes the event name together with the canonical JSON form of the payload.

    Why the payload and not the payload plus import_ts
    --------------------------------------------------
    import_ts is assigned by the ingestion layer at receipt. A redelivery of the same
    webhook gets a different import_ts. Including it in the key would give the duplicate
    a different hash and defeat the whole purpose.

    Known limitation
    ----------------
    Two genuinely distinct events with byte-identical payloads collapse into one row.
    Payloads carry microsecond-resolution timestamps, so this is vanishingly
    unlikely — but it is a real property of this design and worth knowing before you
    rely on exact event counts.

    If Cinder later exposes a delivery ID, replace the body of this macro with it and
    every downstream model inherits the improvement.
-#}

{% macro cinder_event_sk(event_column='event', payload_column='payload') -%}
    md5(
        coalesce({{ event_column }}, '<null_event>')
        || '|'
        || coalesce(to_json({{ payload_column }}), '<null_payload>')
    )
{%- endmacro %}


{#-
    ==================================================================================
    cinder_event_timestamp
    ==================================================================================
    Extracts event time from a payload as TIMESTAMP_TZ.

    Cinder event timestamps are ISO 8601 and timezone-aware, but they are not uniform:
    some carry microseconds and an explicit offset ("2024-05-20T08:58:35.084140+00:00"),
    others are Zulu with no fractional seconds ("2024-05-12T23:15:05Z"). Both appear in
    the documented examples for these three events.

    TRY_TO_TIMESTAMP_TZ handles both and returns null rather than failing on anything
    unexpected — which is the right behaviour here, because a null event time is caught
    by a not_null test and reported, whereas a hard cast failure takes down the build and
    tells you nothing about which row was at fault.

    Always TIMESTAMP_TZ, never TIMESTAMP_NTZ: discarding the offset on a global
    moderation workload silently misattributes events across day boundaries.
-#}

{% macro cinder_event_timestamp(json_path) -%}
    try_to_timestamp_tz({{ json_path }}::varchar)
{%- endmacro %}


{#-
    ==================================================================================
    cinder_normalised_job_category
    ==================================================================================
    Normalises job category across events.

    The two job events name the same concept differently:

      job.actioned  ->  payload.job.job_category
      job.closed    ->  payload.job.category

    and they do not carry the same enum. job.actioned documents four values
    (standard, appeal, qa, golden); job.closed documents six, adding training and
    multi_review.

    Rather than paper over that, staging normalises the column name to job_category and
    the accepted_values test asserts the union of both enums. The difference is real and
    is documented in the model description, so an analyst who sees 'multi_review' in the
    data and not in the job.actioned docs has somewhere to look.
-#}

{% macro cinder_normalised_job_category(job_object) -%}
    coalesce(
          {{ job_object }}:job_category::varchar
        , {{ job_object }}:category::varchar
    )
{%- endmacro %}


{#-
    ==================================================================================
    cinder_surrogate_key
    ==================================================================================
    Thin wrapper over dbt_utils.generate_surrogate_key.

    Two reasons it is worth the indirection:

      1. One place to change. If this project ever drops dbt_utils, or the hashing needs to
         change for a compliance reason, it changes here rather than in a dozen models.

      2. Linting. A namespaced macro call (`dbt_utils.generate_surrogate_key`) cannot be
         stubbed by sqlfluff's jinja templater, which only resolves flat names. Wrapping it
         means the project can be linted with no database connection at all — see .sqlfluff.

    Takes a list of column expressions, exactly like the macro it wraps.
-#}

{% macro cinder_surrogate_key(columns) -%}
    {{ dbt_utils.generate_surrogate_key(columns) }}
{%- endmacro %}
