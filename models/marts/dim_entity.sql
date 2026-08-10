/*
    Conformed entity dimension.

    An entity is whatever was under review — an account, a post, an image, an audio clip,
    or any schema the customer has defined in Cinder.

    THE ATTRIBUTE BAG STAYS A VARIANT. This is the single most important modelling decision
    in the project and the one most often got wrong.

    Cinder's entity attributes are keyed by attribute slug and the slugs differ per
    entity_schema: a `user` carries email and username, a `text_post` carries caption and
    object_url, and a customer-defined schema carries whatever they defined. Flattening this
    into fixed columns does two bad things — it breaks the first time someone adds a schema,
    and until then it silently discards every attribute you did not think of.

    So the generic columns (schema, id, url) are extracted, and the full bag is preserved.
    A few high-value attributes are surfaced as nullable convenience columns because they
    recur across schemas, and each is explicitly documented as "present only for some
    schemas".

    Business key is the pair (entity_schema, entity_id). Ids are only unique within a
    schema — a user and a post can share an id — so keying on id alone would merge
    unrelated entities.

    Note also that this dimension holds attributes as at the LATEST event that mentioned
    the entity, not as at any particular decision. Cinder sends the attribute values that
    were current when the action was taken, so the facts carry their own point-in-time
    snapshot. Use this dimension for current state; use the fact payload for what the
    reviewer actually saw.
*/

with from_decisions as (

    select
          entity_schema
        , entity_id
        , entity_attributes
        , decided_at            as observed_at
        , 'reviewed'            as entity_role
    from {{ ref('stg_cinder__decisions') }}
    where entity_id is not null

    union all

    select
          entity_schema
        , entity_id
        , entity_attributes
        , actioned_at           as observed_at
        , 'reviewed'            as entity_role
    from {{ ref('stg_cinder__job_actions') }}
    where entity_id is not null

    union all

    select
          entity_schema
        , entity_id
        , entity_attributes
        , closed_at             as observed_at
        , 'reviewed'            as entity_role
    from {{ ref('stg_cinder__job_closures') }}
    where entity_id is not null

    union all

    -- Entities that triggered a workflow. Frequently a different entity from the one the
    -- action landed on — a workflow triggered by an account can act on that account's
    -- posts. Included so the dimension covers every entity referenced anywhere, and
    -- tagged so the distinction is not lost. No attribute bag is available on this path.
    select
          trigger_entity_schema  as entity_schema
        , trigger_entity_id      as entity_id
        , null::variant          as entity_attributes
        , actioned_at            as observed_at
        , 'workflow_trigger'     as entity_role
    from {{ ref('stg_cinder__job_actions') }}
    where trigger_entity_id is not null

),

aggregated as (

    select
          entity_schema
        , entity_id
        , min(observed_at)                                          as first_seen_at
        , max(observed_at)                                          as last_seen_at
        , count(*)                                                  as observation_count
        , max(case when entity_role = 'reviewed' then 1 else 0 end) = 1
                                                                    as was_reviewed
        , max(case when entity_role = 'workflow_trigger' then 1 else 0 end) = 1
                                                                    as triggered_a_workflow
    from from_decisions
    group by entity_schema, entity_id

),

latest_attributes as (

    select
          entity_schema
        , entity_id
        , entity_attributes
    from from_decisions
    qualify row_number() over (
        partition by entity_schema, entity_id
        -- Prefer a row that actually carries attributes: a workflow-trigger reference has
        -- none, and letting it win would blank out a perfectly good attribute bag.
        order by
              case when entity_attributes is null then 1 else 0 end
            , observed_at desc nulls last
    ) = 1

)

select
      {{ cinder_surrogate_key(['a.entity_schema', 'a.entity_id']) }}
                                                            as entity_key
    , a.entity_schema
    , a.entity_id

    -- The whole bag, preserved. Query it with entity_attributes:some_slug::varchar.
    , l.entity_attributes

    -- Convenience extractions. Each is nullable and present only for the schemas that
    -- define it — a null username on a text_post is correct, not missing data.
    , l.entity_attributes:object_url::varchar               as entity_object_url
    , l.entity_attributes:username::varchar                 as entity_username
    , l.entity_attributes:email::varchar                    as entity_email
    , l.entity_attributes:caption::varchar                  as entity_caption

    , l.entity_attributes is not null                       as has_attributes
    , a.was_reviewed
    , a.triggered_a_workflow
    , a.first_seen_at
    , a.last_seen_at
    , a.observation_count
from aggregated a
inner join latest_attributes l
    on  a.entity_schema = l.entity_schema
    and a.entity_id = l.entity_id
