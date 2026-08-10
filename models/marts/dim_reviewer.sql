/*
    Conformed reviewer dimension.

    Human actors only. Automated decisions and workflow-driven job actions carry no user
    object, so they are absent here by design rather than represented as an "unknown"
    reviewer. A synthetic unknown member would quietly become the busiest reviewer in the
    business and corrupt every per-reviewer metric.

    Email is the business key, lowercased. It is the only stable identifier the webhooks
    expose — there is no user id — and case can vary between systems.

    GROUP MEMBERSHIP IS A POINT-IN-TIME SNAPSHOT. Cinder sends the groups the user belonged
    to at the moment of the action, so historical facts carry historical membership. This
    dimension holds the most recent view. If you need membership as at a specific decision,
    read it from the fact's own payload lineage rather than joining here — otherwise a
    moderator who changed teams last week will appear to have always been on the new one.

    VENDOR SEGMENTATION IS A NAMING CONVENTION, NOT A FIELD. Outsourced moderation teams
    are distinguishable only by their group names. The parsing below assumes the convention
    "<Vendor> BPO Moderator - <Specialism>". It is the one part of this model most likely to
    need changing for a different naming scheme, and it fails safe: an unmatched name leaves
    the vendor null and `is_outsourced` false rather than guessing.
*/

with from_decisions as (

    select
          lower(trim(reviewer_email))   as reviewer_email
        , reviewer_name
        , reviewer_groups
        , decided_at                    as observed_at
        , 'job.closed'                  as observed_on_event
    from {{ ref('stg_cinder__decisions') }}
    where reviewer_email is not null
      and length(trim(reviewer_email)) > 0

),

from_job_actions as (

    select
          lower(trim(actor_user_email)) as reviewer_email
        , actor_user_name               as reviewer_name
        , actor_user_groups             as reviewer_groups
        , actioned_at                   as observed_at
        , 'job.actioned'                as observed_on_event
    from {{ ref('stg_cinder__job_actions') }}
    where actor_user_email is not null
      and length(trim(actor_user_email)) > 0

),

reviewer_fragments as (

    select * from from_decisions
    union all
    select * from from_job_actions

),

aggregated as (

    select
          reviewer_email
        , min(observed_at)                              as first_seen_at
        , max(observed_at)                              as last_seen_at
        , count(*)                                      as observation_count
        , count(distinct observed_on_event)             as observed_event_type_count
        , count_if(observed_on_event = 'job.closed')    as decision_observation_count
        , count_if(observed_on_event = 'job.actioned')  as action_observation_count
    from reviewer_fragments
    group by reviewer_email

),

latest_attributes as (

    select
          reviewer_email
        , reviewer_name
        , reviewer_groups
    from reviewer_fragments
    qualify row_number() over (
        partition by reviewer_email
        order by observed_at desc nulls last
    ) = 1

),

-- Groups arrive as an array of objects: [{"name": "Admin"}, ...]. Flattened to a sorted
-- array so the semantic layer has something a person can group by, while membership tests
-- stay possible.
group_labels as (

    select
          l.reviewer_email
        , array_agg(g.value:name::varchar) within group (order by g.value:name::varchar)
                                                        as reviewer_group_array

        -- Vendor name, by convention: the text before " BPO" in a vendor group name.
        , max(
              case
                  when g.value:name::varchar ilike '% BPO %'
                  then trim(split_part(g.value:name::varchar, ' BPO ', 1))
              end
          )                                             as vendor_name

        -- Specialism, by the same convention: the text after the final " - ".
        , max(
              case
                  when g.value:name::varchar ilike '% BPO %'
                       and g.value:name::varchar like '% - %'
                  then trim(split_part(g.value:name::varchar, ' - ', -1))
              end
          )                                             as vendor_specialism

    from latest_attributes l
    , lateral flatten(input => l.reviewer_groups) g
    group by l.reviewer_email

)

select
      {{ dbt_utils.generate_surrogate_key(['a.reviewer_email']) }}   as reviewer_key
    , a.reviewer_email
    , l.reviewer_name
    , coalesce(g.reviewer_group_array, array_construct())            as reviewer_group_array
    , array_to_string(coalesce(g.reviewer_group_array, array_construct()), ', ')
                                                                    as reviewer_groups_label

    -- ---- Staffing model -------------------------------------------------------------
    , g.vendor_name
    , g.vendor_specialism
    , g.vendor_name is not null                                     as is_outsourced

    -- Always usable for grouping: the vendor where known, otherwise 'In-house'. Avoids a
    -- null bucket in every staffing breakdown.
    , coalesce(g.vendor_name, 'In-house')                           as staffing_model

    -- ---- Role flags -----------------------------------------------------------------
    -- Derived from group names, so only as reliable as the naming convention — which is
    -- why the full group array stays available alongside them.
    , array_contains('Admin'::variant, coalesce(g.reviewer_group_array, array_construct()))
                                                                    as is_admin
    , array_contains('QA'::variant, coalesce(g.reviewer_group_array, array_construct()))
                                                                    as is_qa
    , array_contains('Escalation Team'::variant, coalesce(g.reviewer_group_array, array_construct()))
                                                                    as is_escalation_team

    , a.observation_count
    , a.decision_observation_count
    , a.action_observation_count
    , a.observed_event_type_count
    , a.first_seen_at
    , a.last_seen_at
from aggregated a
inner join latest_attributes l
    on a.reviewer_email = l.reviewer_email
left join group_labels g
    on a.reviewer_email = g.reviewer_email
