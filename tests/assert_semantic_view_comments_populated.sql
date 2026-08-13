{#-
    ===========================================================================
    Gate: every dimension and fact in the semantic view carries a comment
    ===========================================================================
    WHAT THIS PROTECTS. The comments in this semantic view are no longer written
    in the model — they are pulled from the dbt documentation for the mart column
    each one exposes, by col_comment() in macros/semantic/doc_comment.sql. That
    macro raises at compile time when a description is missing or blank, so a
    broken link cannot normally reach Snowflake.

    THIS TEST CHECKS THE OUTCOME ANYWAY, for the same reason the agent spec test
    does. A semantic view can be replaced by hand in a worksheet, edited in
    Snowsight, or built by an older revision of this project, and none of those
    paths go through the macro. What arrives in Snowflake is what Cortex Analyst
    reads, so that is what gets asserted.

    WHY A BLANK COMMENT IS WORTH FAILING A BUILD OVER. Analyst chooses between
    dimensions using their names, synonyms and comments. Strip the comment and it
    is choosing on the name alone — which is exactly the situation the comments
    exist to prevent, and it degrades answer quality without producing an error
    anywhere. A blank comment is not a cosmetic gap; it is a silent regression in
    the thing this semantic view is for.

    Metrics are deliberately not covered. Their comments are written inline in the
    model because an aggregate has no single mart column to source from, and the
    model header explains why that is not the same drift risk.

    ON THE UNQUALIFIED `information_schema`: the database is deliberately not
    interpolated into the FROM clause. INFORMATION_SCHEMA resolves against the
    session database, which dbt sets from the target, so this is correct at run
    time — and it keeps every piece of Jinja in this file inside a string literal.
    That is what lets sqlfluff parse it. Writing `{{ sv.database }}.information_schema`
    renders to `.information_schema` under sqlfluff's stub context and produces an
    unparsable section, which is why two other tests in this directory had to be
    added to .sqlfluffignore. This one does not need to be.
-#}

{%- set sv = ref('sem_cinder_moderation') -%}

with dimensions as (

    select
          'dimension'         as element_type
        , table_name
        , name
        , comment
    from information_schema.semantic_dimensions
    where semantic_view_catalog = '{{ sv.database | upper }}'
      and semantic_view_schema  = '{{ sv.schema | upper }}'
      and semantic_view_name    = '{{ sv.identifier | upper }}'

),

facts as (

    select
          'fact'              as element_type
        , table_name
        , name
        , comment
    from information_schema.semantic_facts
    where semantic_view_catalog = '{{ sv.database | upper }}'
      and semantic_view_schema  = '{{ sv.schema | upper }}'
      and semantic_view_name    = '{{ sv.identifier | upper }}'

),

everything as (

    select * from dimensions
    union all
    select * from facts

)

-- A row here is a dimension or fact that reached Snowflake with nothing to tell
-- Cortex Analyst about it.
select
      element_type
    , table_name
    , name
    , comment
from everything
where comment is null
   or trim(comment) = ''
