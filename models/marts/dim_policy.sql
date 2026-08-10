/*
    Conformed policy dimension, with hierarchy.

    Policies form a tree: broad areas at the top, specific violations beneath. The wire
    format exposes this as a `parent_id` on each policy — absent, not null, on roots.

    WHY THE HIERARCHY MATTERS. Policy distribution reported at leaf level fragments into
    dozens of thin slices that nobody can read. Rolled up to the parent it becomes the
    chart people actually want. Both levels are exposed here, so distribution can be cut
    either way.

    THE PARENT NAME PROBLEM, and how it is handled honestly. Cinder sends the parent's id
    but not its name. A parent's name is only known if that parent has itself been applied
    directly to some decision, which does happen but is not guaranteed. So:

      * `policy_parent_name` resolves from observed policies where possible.
      * Where the parent has never been seen as a policy in its own right, the name is
        null and `policy_parent_name_resolved` is false.
      * `policy_group_name` gives you something always usable: the parent's name if known,
        otherwise the policy's own name, so a root policy groups under itself rather than
        under a null.

    This dimension is observed, not reference: it contains only policies that have actually
    been applied. A policy configured in Cinder but never used will not appear.
*/

with policy_fragments as (

    select
          policy_id
        , policy_name
        , policy_parent_id
        , policy_is_illegal
        , policy_is_non_violating
        , policy_customer_ref
        , policy_enforcement_actions
        , decided_at            as observed_at
    from {{ ref('stg_cinder__decision_policies') }}
    where policy_id is not null

),

aggregated as (

    select
          policy_id
        , min(observed_at)                                          as first_seen_at
        , max(observed_at)                                          as last_seen_at
        , count(*)                                                  as application_count
    from policy_fragments
    group by policy_id

),

-- Latest observation wins for mutable attributes. Policy trees get renamed, and the
-- current name is the one a reviewer will recognise.
latest_attributes as (

    select
          policy_id
        , policy_name
        , policy_parent_id
        , policy_is_illegal
        , policy_is_non_violating
        , policy_customer_ref
        , policy_enforcement_actions
    from policy_fragments
    qualify row_number() over (
        partition by policy_id
        order by observed_at desc nulls last
    ) = 1

),

-- Self-join to resolve parent names from policies observed in their own right.
parent_names as (

    select
          policy_id       as parent_policy_id
        , policy_name     as parent_policy_name
    from latest_attributes

)

select
      {{ dbt_utils.generate_surrogate_key(['a.policy_id']) }}        as policy_key
    , a.policy_id
    , l.policy_name
    , l.policy_customer_ref

    -- ---- Hierarchy ----------------------------------------------------------------
    , l.policy_parent_id
    , p.parent_policy_name                                          as policy_parent_name
    , l.policy_parent_id is null                                    as is_root_policy
    , l.policy_parent_id is not null and p.parent_policy_name is not null
                                                                    as policy_parent_name_resolved

    -- Always usable for grouping: the parent's name where known, otherwise the policy's
    -- own name. A root policy groups under itself; an unresolved parent groups under the
    -- child rather than collapsing into a null bucket.
    , coalesce(p.parent_policy_name, l.policy_name)                 as policy_group_name

    -- ---- Classification ------------------------------------------------------------
    , l.policy_is_illegal
    , l.policy_is_non_violating

    -- A single readable classification, since "illegal", "violating" and "non-violating"
    -- are the three cuts that actually get asked for.
    , case
          when l.policy_is_non_violating then 'non_violating'
          when l.policy_is_illegal then 'illegal'
          else 'violating'
      end                                                           as policy_severity_class

    -- ---- Enforcement configured on the policy --------------------------------------
    -- The actions this policy calls for, as at its latest application. Distinct from what
    -- was actually applied on any given decision.
    , coalesce(l.policy_enforcement_actions, array_construct())      as policy_enforcement_actions
    , array_size(coalesce(l.policy_enforcement_actions, array_construct()))
                                                                    as policy_enforcement_action_count

    , a.application_count
    , a.first_seen_at
    , a.last_seen_at
from aggregated a
inner join latest_attributes l
    on a.policy_id = l.policy_id
left join parent_names p
    on l.policy_parent_id = p.parent_policy_id
