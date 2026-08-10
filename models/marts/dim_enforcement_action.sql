/*
    Conformed enforcement action dimension.

    Enforcement actions arrive as bare slugs — no id, no display name, no severity, no
    metadata of any kind. So this dimension is derived entirely from observed usage, with
    the same limitation as dim_queue: an action configured in Cinder but never applied does
    not appear.

    Because there is no metadata to inherit, the severity ordering and grouping below are a
    LOCAL CONVENTION defined in this project, not something Cinder supplies. They exist so
    a semantic layer can sort actions by seriousness rather than alphabetically, and so
    "most severe action on this decision" is answerable at all.

    THIS IS THE ONE PART OF THIS PROJECT YOU ARE EXPECTED TO EDIT. Replace the ladder below
    with your own enforcement ladder. Anything unrecognised falls to rank 0 and the
    'unclassified' category rather than being guessed into a bucket, so a new action shows
    up as unclassified instead of quietly landing in the wrong place.
*/

with action_fragments as (

    select
          enforcement_action_slug
        , decided_at            as observed_at
        , is_automated
        , is_no_action
    from {{ ref('stg_cinder__decision_enforcement_actions') }}
    where enforcement_action_slug is not null

),

aggregated as (

    select
          enforcement_action_slug
        , min(observed_at)                          as first_seen_at
        , max(observed_at)                          as last_seen_at
        , count(*)                                  as application_count
        , count_if(is_automated)                    as automated_application_count
    from action_fragments
    group by enforcement_action_slug

)

select
      {{ dbt_utils.generate_surrogate_key(['enforcement_action_slug']) }}
                                                    as enforcement_action_key
    , enforcement_action_slug
    , initcap(replace(enforcement_action_slug, '_', ' '))
                                                    as enforcement_action_name

    -- LOCAL CONVENTION — see the header. Higher means more severe.
    , case enforcement_action_slug
          when 'no_action'         then 0
          when 'warn_user'         then 1
          when 'shadow_ban'        then 2
          when 'remove_content'    then 3
          when 'restrict_account'  then 4
          when 'ban_user'          then 5
          else 0
      end                                           as enforcement_severity_rank

    -- What the action acts upon. The distinction between removing a piece of content and
    -- restricting the account behind it is the one moderation leads care about.
    , case enforcement_action_slug
          when 'no_action'         then 'none'
          when 'warn_user'         then 'advisory'
          when 'shadow_ban'        then 'visibility'
          when 'remove_content'    then 'content'
          when 'restrict_account'  then 'account'
          when 'ban_user'          then 'account'
          else 'unclassified'
      end                                           as enforcement_category

    , enforcement_action_slug in (
          'no_action', 'warn_user', 'shadow_ban', 'remove_content',
          'restrict_account', 'ban_user'
      )                                             as is_recognised_action

    -- `no_action` is a recorded outcome, not an absence of one. Flagged so consumers can
    -- exclude it from enforcement counts deliberately rather than by accident.
    , enforcement_action_slug = 'no_action'         as is_no_action

    , application_count
    , automated_application_count
    , application_count - automated_application_count
                                                    as human_application_count
    , first_seen_at
    , last_seen_at
from aggregated
