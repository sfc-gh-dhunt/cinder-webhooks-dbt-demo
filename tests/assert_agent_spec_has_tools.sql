{#-
    ===========================================================================
    Gate: the deployed agent spec still carries its tools
    ===========================================================================
    THIS TEST EXISTS BECAUSE OF A SPECIFIC, SILENT, EXPENSIVE FAILURE.

    `ALTER AGENT ... MODIFY LIVE VERSION SET SPECIFICATION` REPLACES the entire
    specification. It does not merge. Send a spec containing only a `models:`
    block and every tool and every tool_resource is removed — and nothing errors,
    because that is the documented behaviour of the statement. One team ran 113
    such statements against 50-plus agents and lost all their semantic view
    references; the incident record for it notes, in the field meant for the error
    message, that no error was thrown and the commands succeeded as designed.

    macros/materializations/cortex_agent.sql defends against this structurally:
    the model body is always the complete spec, so a partial update is not
    expressible through it. This test is the second line — it verifies the
    OUTCOME rather than trusting the mechanism, which matters because the agent
    can also be changed by hand in Snowsight, by another pipeline, or by a
    well-meaning `ALTER` in a worksheet.

    A tool disappearing is not cosmetic. An agent with no Cortex Analyst tool
    still answers, fluently, from the model's own knowledge — so the failure looks
    like a quality problem rather than a configuration one, and the eval gate may
    not catch it if the questions are answerable plausibly without data.

    WHY THIS READS AT COMPILE TIME. `SHOW VERSIONS IN AGENT` is a metadata
    command: its output is only reachable through RESULT_SCAN on its own query id,
    which a single-statement dbt test cannot express. So the SHOW runs here via
    run_query and the result is folded into a literal assertion. The cost is that
    the check reflects state at compile time rather than at query time, which for
    a post-deploy assertion in the same invocation is the state we care about.

    WHICH VERSION IS CHECKED: the DEFAULT one, because that is what the agent
    actually serves. Checking the live version would pass while production served
    something else — and the two diverging is normal, since committing destroys
    the live version until it is recreated.
-#}

{{ config(severity='error') }}

{#- Attaches this test to the agent in the DAG so graph selection includes it.
    See the equivalent note in assert_agent_eval_scores.sql. -#}
{%- do ref('agent_cinder_moderation') -%}

{#- Schema derived from the model, not hardcoded: schemas here are namespaced per
    pull request, so a literal would check production's agent from a CI run. -#}
{%- set agent_relation = ref('agent_cinder_moderation') -%}
{%- set agent_db = agent_relation.database -%}
{%- set agent_schema = agent_relation.schema -%}
{%- set agent_identifier = agent_relation.identifier -%}
{%- set agent_fqn = agent_db ~ '.' ~ agent_schema ~ '.' ~ agent_identifier -%}

{#- What the spec must still contain. The tool name and the semantic view are the
    two things the partial-spec failure removes. -#}
{%- set required_fragments = [
    'cortex_analyst_text_to_sql',
    'cinder_moderation',
    'SEM_CINDER_MODERATION'
] -%}

{%- set problems = [] -%}

{%- if execute -%}

    {#- Absence is not this test's business — if the agent was never built, the
        model would have failed first and reporting it twice obscures the cause. -#}
    {%- set exists = run_query(
        "show agents like '" ~ agent_identifier ~ "' in schema " ~ agent_db ~ "." ~ agent_schema
    ) -%}

    {%- if exists | length > 0 -%}

        {%- set versions = run_query("show versions in agent " ~ agent_fqn) -%}

        {%- set ns = namespace(spec=none, version=none) -%}
        {%- for row in versions -%}
            {#- is_default marks the served version. Booleans come back from SHOW
                as either a bool or the string 'true' depending on driver, so
                compare loosely rather than with `is true`. -#}
            {%- set is_def = row['is_default'] | string | lower -%}
            {%- if is_def in ['true', '1'] -%}
                {%- set ns.spec = row['agent_spec'] | string -%}
                {%- set ns.version = row['name'] | string -%}
            {%- endif -%}
        {%- endfor -%}

        {%- if ns.spec is none -%}
            {#- No default version at all. The materialization always promotes, so
                this means something else unpinned it, and the agent's served
                behaviour is now whatever Snowflake resolves implicitly. -#}
            {%- do problems.append(
                'NO_DEFAULT_VERSION|Agent ' ~ agent_fqn ~ ' has no default version. '
                ~ 'Nothing is explicitly promoted, so what it serves is not pinned.'
            ) -%}
        {%- else -%}
            {%- set spec_upper = ns.spec | upper -%}
            {%- for fragment in required_fragments -%}
                {%- if fragment | upper not in spec_upper -%}
                    {%- do problems.append(
                        'MISSING_FROM_SPEC|Version ' ~ ns.version ~ ' of ' ~ agent_fqn
                        ~ ' no longer contains "' ~ fragment
                        ~ '". A partial ALTER can strip tools without raising an error.'
                    ) -%}
                {%- endif -%}
            {%- endfor -%}
        {%- endif -%}

    {%- endif -%}

{%- endif -%}


{#- Emit one row per problem. No problems means no rows, which is a pass. -#}
{%- if problems | length == 0 -%}

select
    'never' as failure,
    'no problems found' as detail
where false

{%- else -%}

{% for problem in problems %}
select
    '{{ problem.split("|")[0] }}' as failure,
    '{{ problem.split("|")[1] | replace("'", "''") }}' as detail
{% if not loop.last %}union all{% endif %}
{% endfor %}

{%- endif -%}
