-- =====================================================================================
-- Semantic view comments, sourced from the dbt documentation
-- =====================================================================================
-- WHY THIS EXISTS. Before this, every COMMENT in the semantic view was a hard-coded
-- string. The same column was therefore documented twice — once in models/marts/schema.yml
-- for dbt, once again in the semantic view for Cortex Analyst — and nothing kept the two
-- in step. Renaming a mart column or rewriting its description left the semantic layer
-- describing the previous version of the data, which is worse than no description at all:
-- Analyst treats the comment as authoritative and has no way to notice it has gone stale.
--
-- These macros make the dbt documentation the only source. The semantic view asks for a
-- column's description by (model, column) and gets whatever schema.yml currently says.
--
-- HOW DOC BLOCKS SURVIVE THE TRIP. dbt renders `{{ doc('...') }}` inside a schema.yml
-- description at PARSE time and stores the rendered text in the manifest. `graph` is that
-- manifest. So a definition written once in a dbt docs block, referenced from several
-- models' schema.yml, arrives here already resolved — the sharing works without this macro
-- knowing anything about doc blocks. That matters because it CANNOT know about them:
-- `graph` exposes nodes, sources, metrics, exposures, semantic_models and saved_queries,
-- and no `docs` collection. `doc()` itself is unavailable here too — it belongs to dbt's
-- schema-YAML rendering context, not the model context. Going through a column description
-- is the only route, and it is enough.
--
-- WHY A MISSING DESCRIPTION IS A HARD ERROR. The failure mode this replaces was silence.
-- If a lookup returned an empty string, a typo'd column name or a description deleted in a
-- refactor would produce a semantic view that builds cleanly with blank comments, and the
-- damage would only show up as Analyst picking the wrong dimension weeks later. Raising
-- instead means the pull request that breaks the link is the pull request that fails.
-- =====================================================================================


{% macro sv_escape(text) -%}
  {#-
  --  Make a description safe to sit inside a single-quoted SQL literal, on one line.
  --
  --  Two things happen. Single quotes are doubled, because a description containing an
  --  apostrophe would otherwise terminate the literal and produce a syntax error several
  --  lines further on. And all runs of whitespace collapse to one space, because
  --  schema.yml folded blocks (`description: >`) carry newlines that would otherwise be
  --  emitted into the middle of the DDL and make the generated statement hard to read.
  --  `.split()` with no argument splits on any run of whitespace, which does both the
  --  newline removal and the collapsing in one step.
  -#}
  {{- (text | string).split() | join(' ') | replace("'", "''") -}}
{%- endmacro %}


{% macro sv_node(model_name) -%}
  {#-
  --  Find a model's manifest entry by name. Returns none when the graph is not populated.
  -#}
  {%- set matches = graph.nodes.values()
        | selectattr('resource_type', 'equalto', 'model')
        | selectattr('name', 'equalto', model_name)
        | list -%}
  {%- if matches | length > 1 -%}
    {{- exceptions.raise_compiler_error(
          "sv_node: '" ~ model_name ~ "' matches " ~ (matches | length) ~ " models. "
          ~ "Qualify the name or rename one of them.") -}}
  {%- endif -%}
  {{- return(matches[0] if matches else none) -}}
{%- endmacro %}


{% macro col_comment(model_name, column_name) -%}
  {#-
  --  A semantic view COMMENT taken from a mart column's dbt description.
  --
  --  Usage:
  --      queues.queue_name AS queues.queue_name
  --          COMMENT = '{{ col_comment('dim_queue', 'queue_name') }}'
  --
  --  PARSE TIME RETURNS EMPTY, DELIBERATELY. `graph` is only populated for run and
  --  compile; during `dbt parse` it is an empty dict. Raising then would break parsing,
  --  and parsing is what CI runs to validate the project without a warehouse. So an
  --  unpopulated graph is treated as "not my turn" rather than as a missing description.
  -#}
  {%- if not graph or not graph.get('nodes') -%}
    {{- return('') -}}
  {%- endif -%}

  {%- set node = cinder_webhooks.sv_node(model_name) -%}
  {%- if node is none -%}
    {{- exceptions.raise_compiler_error(
          "col_comment: no model named '" ~ model_name ~ "'. "
          ~ "The semantic view references a model that does not exist.") -}}
  {%- endif -%}

  {#- schema.yml keys keep their authored case; compare case-insensitively so the semantic
      view can reference columns the way Snowflake reports them.

      `present` is tracked separately from `desc` on purpose. A column declared in
      schema.yml with tests but no `description:` arrives as an empty string, not as
      missing — so testing the description alone cannot tell "you referenced a column that
      does not exist" apart from "the column exists but nobody wrote a description". Those
      are different mistakes with different fixes, and the error message should say which. -#}
  {%- set wanted = column_name | lower -%}
  {%- set found = namespace(desc='', present=false) -%}
  {%- for key, col in node.columns.items() -%}
    {%- if not found.present and key | lower == wanted -%}
      {%- set found.present = true -%}
      {%- set found.desc = col.get('description') or '' -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if not found.present -%}
    {{- exceptions.raise_compiler_error(
          "col_comment: '" ~ model_name ~ "' has no column '" ~ column_name
          ~ "' in schema.yml. Either the column was renamed and the semantic view was not "
          ~ "updated, or the column is not documented yet. Add it to models/marts/schema.yml.") -}}
  {%- endif -%}

  {%- if not (found.desc | trim) -%}
    {{- exceptions.raise_compiler_error(
          "col_comment: '" ~ model_name ~ "." ~ column_name ~ "' is declared in schema.yml "
          ~ "but has no description. The semantic view relies on it, so this would publish "
          ~ "a blank comment to Cortex Analyst. Write a description.") -}}
  {%- endif -%}

  {{- cinder_webhooks.sv_escape(found.desc) -}}
{%- endmacro %}


{% macro model_comment(model_name) -%}
  {#-
  --  A semantic view logical-table COMMENT taken from a mart model's dbt description.
  --
  --  The full description is used rather than its first sentence. These descriptions carry
  --  the grain and the counting traps that go with it — which is exactly the context that
  --  stops Analyst summing a measure at the wrong grain — so truncating them would throw
  --  away the most useful part to save a few hundred characters of DDL.
  -#}
  {%- if not graph or not graph.get('nodes') -%}
    {{- return('') -}}
  {%- endif -%}

  {%- set node = cinder_webhooks.sv_node(model_name) -%}
  {%- if node is none -%}
    {{- exceptions.raise_compiler_error(
          "model_comment: no model named '" ~ model_name ~ "'.") -}}
  {%- endif -%}

  {%- if not ((node.get('description') or '') | trim) -%}
    {{- exceptions.raise_compiler_error(
          "model_comment: model '" ~ model_name ~ "' has no description in schema.yml. "
          ~ "The semantic view publishes it as the logical table's comment.") -}}
  {%- endif -%}

  {{- cinder_webhooks.sv_escape(node.description) -}}
{%- endmacro %}
