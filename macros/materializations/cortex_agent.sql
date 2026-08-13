{#-
    =========================================================================
    cortex_agent — an ALTER-based materialization for Snowflake Cortex Agents
    =========================================================================
    Turns a dbt model into a Cortex Agent. The model body IS the agent
    specification YAML; everything here is lifecycle management around it.

    ############################################################################
    # WHY THIS IS NOT `CREATE OR REPLACE AGENT`. READ BEFORE CHANGING.         #
    ############################################################################

    `CREATE OR REPLACE AGENT` drops and recreates the object. That resets its
    version history and severs the link to every prior evaluation run and
    observability event, because a replaced agent is a NEW object with a new
    internal id. Nothing errors. You discover it the day you need history and
    find a day of it.

    This is not theoretical. It was verified directly on this account: an agent
    holding VERSION$1 and VERSION$2 was subjected to a `create or replace` and
    came back with a single fresh VERSION$1. It has also happened in production
    elsewhere — a daily dbt materialization built on `CREATE OR REPLACE AGENT`
    left observability queries returning roughly one day of data, and the fix
    was precisely the branch this file implements.

    So: create only when absent, ALTER thereafter. There is deliberately NO
    `CREATE OR REPLACE` path and no `--full-refresh` escape hatch, because the
    escape hatch is the bug.

    ############################################################################
    # THE FOUR TRAPS THIS FILE EXISTS TO DEFEAT                               #
    ############################################################################

    1. REPLACE DESTROYS HISTORY — above. Handled by branching on existence.

    2. `COMMIT` DESTROYS THE LIVE VERSION. After a commit there is no live
       version until you `ADD LIVE VERSION FROM LAST`. So the second run of this
       materialization hits a different state than the first, and a naive
       implementation that always calls `ADD LIVE VERSION` fails on run one
       while one that never calls it fails on run two. Both branches are needed;
       see step 3.

    3. `COMMIT` DOES NOT PROMOTE. It creates an immutable named version. It does
       not make that version the one being served. Snowflake follows the newest
       committed version only IMPLICITLY, and that stops the moment
       DEFAULT_VERSION is pinned out of band — most commonly by the Snowsight
       publish button. Once pinned, every later `dbt run` commits a version
       nobody ever sees while the UI keeps showing an old one as in use. So this
       materialization promotes EXPLICITLY on every deploy, which makes the
       outcome the same whether or not somebody has been clicking in the UI.

    4. A PARTIAL SPEC SILENTLY DESTROYS TOOLS. `ALTER AGENT ... SET
       SPECIFICATION` REPLACES the whole spec — it does not merge. Sending a
       spec containing only `models:` will strip every tool and tool_resource
       without raising anything. One team ran 113 such statements and lost the
       semantic view references on more than fifty agents; the incident record
       notes the commands "succeeded as designed".

       Structural defence: the model body is the complete spec, always. There is
       no partial-update config here, so a partial update is not expressible.
       Belt and braces: tests/assert_agent_spec_has_tools.sql asserts the
       committed spec still carries its tools after every deploy.

    ############################################################################
    # VERSION BLOAT, AND WHY THE COMMENT CARRIES A HASH                       #
    ############################################################################

    Committing on every run would mint a new immutable version per `dbt run`
    whether or not anything changed, and `dbt build` runs a lot. So the spec is
    fingerprinted and the fingerprint is written into the version comment. On
    the next run, if the newest version's comment carries the same fingerprint,
    the spec has not changed: skip the modify and the commit, and only make sure
    DEFAULT_VERSION still points at it.

    That makes reruns genuinely idempotent rather than merely harmless, and it
    means version history reads as a list of real changes.

    ############################################################################
    # NOTES ON THE SNOWFLAKE SURFACE, LEARNED THE HARD WAY                    #
    ############################################################################

    * `SHOW VERSIONS IN AGENT` returns the live version as a row whose `name` is
      EMPTY. That empty name is the only way to distinguish it. Do not look for
      a row called 'LIVE'.

    * `SET DEFAULT_VERSION` requires a QUOTED value. The unquoted form printed
      in the Snowflake documentation (`SET DEFAULT_VERSION = LAST`) fails to
      compile — verified. Only `'VERSION$N'`, `'FIRST'`, `'LAST'` work.

    * `ALTER AGENT ... SET ALIAS` does not exist; aliases are version-level
      (`MODIFY VERSION <v> SET ALIAS = ...`). Alias-based promotion belongs in
      the deploy pipeline, not here, because a dbt run should not decide what
      production serves. This materialization moves DEFAULT_VERSION only.

    * `CREATE AGENT` creates VERSION$1 AND a live version in one go, so the
      create path must NOT commit — VERSION$1 already holds the spec and
      committing would mint an identical VERSION$2.

    * None of this DDL appears in the `ALTER AGENT` SQL reference. It is
      documented only in the Cortex Agent versioning user guide.

    ############################################################################
    # CONFIG                                                                  #
    ############################################################################
      materialized='cortex_agent'    required
      profile={...} | '<json>'       optional  agent PROFILE (display name etc.)
      agent_comment='...'            optional  COMMENT on the agent object
      version_comment='...'          optional  prefix for the version comment
      set_default_version=true       optional  default true; see trap 3
      agent_grants={'USAGE': [...]}  optional  roles to grant USAGE to

    Runs as a no-op relation of type `view` so dbt can track it in the graph.
    dbt has no agent relation type, and no view is ever created — the same
    approach the Snowflake-Labs semantic_view materialization takes.
-#}

{% materialization cortex_agent, adapter='snowflake' -%}

    {%- set spec = sql -%}

    {#- The spec is injected between $$ delimiters. A $$ inside it would end the
        literal early and produce a baffling syntax error a long way from the
        cause, so refuse it up front with a message that names the fix. -#}
    {%- if '$$' in spec -%}
        {%- do exceptions.raise_compiler_error(
            "Agent spec for '" ~ model.name ~ "' contains '$$', which terminates the "
            ~ "specification literal. Remove it, or quote the containing string differently."
        ) -%}
    {%- endif -%}

    {%- set agent_fqn = this.database ~ '.' ~ this.schema ~ '.' ~ this.identifier -%}
    {%- set set_default = config.get('set_default_version', true) -%}
    {%- set profile = config.get('profile', none) -%}
    {%- set agent_comment = config.get('agent_comment', none) -%}
    {%- set version_comment = config.get('version_comment', 'dbt deploy') -%}

    {#- Fingerprint of the spec, used to decide whether a commit is warranted.
        local_md5 is content-only: it deliberately ignores the comment, so
        editing version_comment alone does not mint a version. -#}
    {%- set spec_hash = local_md5(spec) -%}
    {%- set hash_marker = 'spec_md5=' ~ spec_hash -%}
    {%- set full_version_comment = version_comment ~ ' [' ~ hash_marker ~ ']' -%}

    {%- set original_query_tag = set_query_tag() -%}

    {%- call statement('main') -%}
        select 1 as agent_materialization_placeholder
    {%- endcall -%}

    {% if execute %}

        {#- ---------------------------------------------------------------
            Step 1 — does the agent already exist?

            `SHOW AGENTS LIKE` rather than `DESCRIBE`, because DESCRIBE raises
            on a missing object and a raise is not a branch. LIKE returns zero
            rows, which is.
        ---------------------------------------------------------------- -#}
        {%- set existing = run_query(
            "show agents like '" ~ this.identifier ~ "' in schema "
            ~ this.database ~ "." ~ this.schema
        ) -%}
        {%- set agent_exists = existing | length > 0 -%}

        {%- if not agent_exists -%}

            {#- -----------------------------------------------------------
                Step 2a — create. This is the ONLY path that creates, and it
                runs once in the object's lifetime.

                No COMMIT here: CREATE AGENT already produces VERSION$1 holding
                this spec, plus a live version. Committing would mint an
                identical VERSION$2 and make the history lie about what
                changed.
            ------------------------------------------------------------ -#}
            {%- do log("Creating agent " ~ agent_fqn ~ " (did not exist)", info=true) -%}

            {%- set create_sql -%}
                create agent {{ agent_fqn }}
                {%- if profile %}
                    profile = '{{ (profile | tojson) if profile is mapping else profile }}'
                {%- endif %}
                {%- if agent_comment %}
                    comment = '{{ agent_comment | replace("'", "''") }}'
                {%- endif %}
                from specification $${{ spec }}$$
            {%- endset -%}
            {%- do run_query(create_sql) -%}

            {#- Record the fingerprint against VERSION$1 so the next run can
                tell whether the spec has moved. CREATE takes no version
                comment, so it is set afterwards. -#}
            {%- do run_query(
                "alter agent " ~ agent_fqn ~ " modify version VERSION$1 set comment = '"
                ~ full_version_comment | replace("'", "''") ~ "'"
            ) -%}

            {%- set promote_to = 'VERSION$1' -%}

        {%- else -%}

            {#- -----------------------------------------------------------
                Step 2b — the agent exists. Read its versions and decide.
            ------------------------------------------------------------ -#}
            {%- set versions = run_query("show versions in agent " ~ agent_fqn) -%}

            {%- set named = [] -%}
            {%- set live_rows = [] -%}
            {%- for row in versions -%}
                {#- The live version is the row with an EMPTY name. -#}
                {%- if row['name'] is none or row['name'] | trim == '' -%}
                    {%- do live_rows.append(row) -%}
                {%- else -%}
                    {%- do named.append(row) -%}
                {%- endif -%}
            {%- endfor -%}

            {#- Highest VERSION$N, compared NUMERICALLY. Sorting these as
                strings puts VERSION$9 above VERSION$10, which would promote a
                stale version and be extremely hard to spot. -#}
            {%- set ns = namespace(top_n=0, top_name=none, top_comment='') -%}
            {%- for row in named -%}
                {%- set nm = row['name'] | string -%}
                {%- if nm.startswith('VERSION$') -%}
                    {%- set n = nm.split('$')[1] | int -%}
                    {%- if n > ns.top_n -%}
                        {%- set ns.top_n = n -%}
                        {%- set ns.top_name = nm -%}
                        {%- set ns.top_comment = (row['comment'] | string) if row['comment'] is not none else '' -%}
                    {%- endif -%}
                {%- endif -%}
            {%- endfor -%}

            {%- if ns.top_name is not none and hash_marker in ns.top_comment -%}

                {#- -------------------------------------------------------
                    Step 3a — spec unchanged. Do not mint a version.

                    Still fall through to promotion: DEFAULT_VERSION may have
                    been pinned elsewhere since the last run (trap 3), and
                    re-asserting it is what makes this self-healing.
                -------------------------------------------------------- -#}
                {%- do log(
                    "Agent " ~ agent_fqn ~ " spec unchanged (" ~ ns.top_name
                    ~ " matches fingerprint) — skipping commit", info=true
                ) -%}
                {%- set promote_to = ns.top_name -%}

            {%- else -%}

                {#- -------------------------------------------------------
                    Step 3b — spec changed. Update the live version, then
                    commit it.

                    The ADD LIVE VERSION branch is trap 2. After a previous
                    commit there is no live version, and `MODIFY LIVE VERSION`
                    would fail; but calling ADD when one already exists ALSO
                    fails. So it is conditional, and both states occur in
                    normal operation — a fresh agent has a live version, an
                    agent this materialization has already committed does not.
                -------------------------------------------------------- -#}
                {%- if live_rows | length == 0 -%}
                    {%- do log("No live version on " ~ agent_fqn ~ " — adding one from LAST", info=true) -%}
                    {%- do run_query("alter agent " ~ agent_fqn ~ " add live version from last") -%}
                {%- endif -%}

                {#- The complete spec, every time. See trap 4. -#}
                {%- do run_query(
                    "alter agent " ~ agent_fqn ~ " modify live version set specification = $$"
                    ~ spec ~ "$$"
                ) -%}

                {%- if agent_comment -%}
                    {%- do run_query(
                        "alter agent " ~ agent_fqn ~ " set comment = '"
                        ~ agent_comment | replace("'", "''") ~ "'"
                    ) -%}
                {%- endif -%}

                {%- do run_query(
                    "alter agent " ~ agent_fqn ~ " commit comment = '"
                    ~ full_version_comment | replace("'", "''") ~ "'"
                ) -%}

                {#- Re-read rather than assuming top_n + 1. Another session may
                    have committed between the SHOW above and this COMMIT, in
                    which case the version we just made is not the number we
                    predicted — and promoting a predicted number would promote
                    somebody else's work. -#}
                {%- set after = run_query("show versions in agent " ~ agent_fqn) -%}
                {%- set ns2 = namespace(top_n=0, top_name=none) -%}
                {%- for row in after -%}
                    {%- set nm = (row['name'] | string) if row['name'] is not none else '' -%}
                    {%- if nm.startswith('VERSION$') -%}
                        {%- set n = nm.split('$')[1] | int -%}
                        {%- if n > ns2.top_n -%}
                            {%- set ns2.top_n = n -%}
                            {%- set ns2.top_name = nm -%}
                        {%- endif -%}
                    {%- endif -%}
                {%- endfor -%}
                {%- set promote_to = ns2.top_name -%}

                {%- do log("Committed " ~ promote_to ~ " on " ~ agent_fqn, info=true) -%}

            {%- endif -%}

        {%- endif -%}

        {#- ---------------------------------------------------------------
            Step 4 — promote explicitly. Trap 3.

            Quoted, because the unquoted form the docs print does not compile.
        ---------------------------------------------------------------- -#}
        {%- if set_default and promote_to is not none -%}
            {%- do run_query(
                "alter agent " ~ agent_fqn ~ " set default_version = '" ~ promote_to ~ "'"
            ) -%}
            {%- do log("Default version of " ~ agent_fqn ~ " set to " ~ promote_to, info=true) -%}
        {%- endif -%}

        {#- ---------------------------------------------------------------
            Step 5 — grants.

            Not `apply_grants()`: dbt's grant handling works through relation
            types it understands, and an agent is not one of them. Kept
            deliberately simple and additive.
        ---------------------------------------------------------------- -#}
        {%- set agent_grants = config.get('agent_grants', {}) -%}
        {%- for privilege, grantees in agent_grants.items() -%}
            {%- for grantee in grantees -%}
                {%- do run_query(
                    "grant " ~ privilege ~ " on agent " ~ agent_fqn ~ " to role " ~ grantee
                ) -%}
            {%- endfor -%}
        {%- endfor -%}

    {% endif %}

    {%- do unset_query_tag(original_query_tag) -%}

    {#- An agent is not a relation dbt models. Returning a view-typed handle is
        what puts the node in the graph so `ref()` and `--select ...+` work; no
        view is created. Same device the semantic_view materialization uses. -#}
    {%- do return({'relations': [this.incorporate(type='view')]}) -%}

{%- endmaterialization %}
