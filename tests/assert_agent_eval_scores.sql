{#-
    ===========================================================================
    Gate: the agent's evaluation scores clear their thresholds, with no regression
    ===========================================================================
    This is the assertion half of the eval split. The paid, slow, async work of
    invoking the agent and judging it happens in
    models/agents/eval_cinder_moderation.sql. This test only reads the scores it
    produced, which is free, fast and deterministic — so a flaky judge can be
    re-graded without re-spending credits, and thresholds can be tightened
    without touching a materialization.

    GATE ON REGRESSION AS WELL AS ABSOLUTE SCORE, and the distinction is the
    point of having a gate at all. An absolute threshold answers "is this good
    enough". A regression check answers "did this change break something that
    used to work" — which is the question a pull request is actually asking. An
    agent can hold a respectable mean while silently losing the three questions
    somebody complained about last month, and only the second check catches that.

    THE FAILURE MODE THIS FILE WORRIES ABOUT MOST IS PASSING VACUOUSLY. A gate
    that returns zero rows because it read no scores looks identical to a gate
    that returned zero rows because everything passed. So when an evaluation was
    supposed to have run, an empty result set is treated as a FAILURE, not a pass.

    WHY THE RUN NAMES ARE RESOLVED IN JINJA rather than in SQL. Run names carry
    dbt's invocation id, so they are not knowable when this file is written, and
    `GET_AI_EVALUATION_DATA` takes the run name as a scalar argument rather than
    joining to it. Reading the runs table at compile time and inlining the two
    most recent names is the straightforward way to get both a current and a
    baseline set into one query.

    Thresholds are vars so a pull request can be graded more strictly than a
    local run without editing this file:
        dbt test --vars '{eval_min_answer_correctness: 0.9}'
-#}

{{ config(severity='error') }}

{#- Attaches this test to the eval model in the DAG, so `--select
    agent_cinder_moderation+` picks it up. Without a ref a singular test is an
    orphan: it runs on a bare `dbt test` but is invisible to graph selection, so
    the pull-request check would deploy and evaluate the agent and then never
    grade it. `do ref` registers the edge without emitting SQL. -#}
{%- do ref('eval_cinder_moderation') -%}

{%- set min_correctness = var('eval_min_answer_correctness', 0.7) -%}
{%- set min_consistency = var('eval_min_logical_consistency', 0.7) -%}
{%- set eval_ran = var('eval_run', false) -%}

{%- set runs_table = target.database ~ '.' ~ 'SEMANTIC' ~ '.eval_cinder_moderation__runs' -%}

{#- Resolve the current and previous run. Wrapped in `execute` because this runs
    at parse time too, when no query may be issued. -#}
{%- set current_run = none -%}
{%- set previous_run = none -%}
{%- set agent_db = target.database -%}
{%- set agent_schema = 'SEMANTIC' -%}
{%- set agent_name = 'agent_cinder_moderation' -%}

{%- if execute -%}
    {%- set runs_exist = run_query(
        "select count(*) as n from " ~ target.database ~ ".information_schema.tables "
        ~ "where table_schema = '" ~ agent_schema ~ "' "
        ~ "and table_name = 'EVAL_CINDER_MODERATION__RUNS'"
    ) -%}
    {%- set have_table = (runs_exist.columns[0].values()[0] | int) > 0 -%}

    {%- if have_table -%}
        {%- set recent = run_query(
            "select run_name, agent_database, agent_schema, agent_name "
            ~ "from " ~ runs_table ~ " order by created_at desc limit 2"
        ) -%}
        {%- if recent | length > 0 -%}
            {%- set current_run = recent.columns[0].values()[0] -%}
            {%- set agent_db = recent.columns[1].values()[0] or target.database -%}
            {%- set agent_schema = recent.columns[2].values()[0] or agent_schema -%}
            {%- set agent_name = recent.columns[3].values()[0] or agent_name -%}
        {%- endif -%}
        {%- if recent | length > 1 -%}
            {%- set previous_run = recent.columns[0].values()[1] -%}
        {%- endif -%}
    {%- endif -%}
{%- endif -%}


{%- if current_run is none -%}

    {#- No run recorded.

        If `eval_run` was false, no evaluation was requested and this is the
        expected state — return no rows and pass, because the pull request did not
        ask to be graded. The staged config is still validated by the model.

        If `eval_run` was TRUE, a run was requested and there is no record of it.
        That is a harness failure and must be loud: fail with a row that says so
        rather than passing on absent evidence.
    -#}
    {%- if eval_ran -%}
        select
            'NO_EVAL_RUN_RECORDED' as failure,
            'eval_run was true but no row exists in {{ runs_table }}. The evaluation did not run.'
                as detail
    {%- else -%}
        select
            'never' as failure,
            'skipped' as detail
        where false
    {%- endif -%}

{%- else -%}

with current_scores as (

    select
        record_id,
        input,
        metric_name,
        eval_agg_score
    from table({{ agent_db }}.snowflake.local.get_ai_evaluation_data(
        '{{ agent_db }}',
        '{{ agent_schema }}',
        '{{ agent_name }}',
        'CORTEX AGENT',
        '{{ current_run }}'
    ))
    where eval_agg_score is not null

),

{% if previous_run %}
baseline_scores as (

    select
        input,
        metric_name,
        eval_agg_score
    from table({{ agent_db }}.snowflake.local.get_ai_evaluation_data(
        '{{ agent_db }}',
        '{{ agent_schema }}',
        '{{ agent_name }}',
        'CORTEX AGENT',
        '{{ previous_run }}'
    ))
    where eval_agg_score is not null

),
{% endif %}

-- Check 1 — the mean score per metric clears its threshold.
--
-- Mean rather than min: a single hard question scoring badly is a fact about the
-- question set, not a regression, and gating on the minimum makes the suite
-- impossible to extend with anything difficult.
threshold_failures as (

    select
        'THRESHOLD' as failure,
        metric_name
            || ' mean score '
            || to_varchar(round(avg(eval_agg_score), 3))
            || ' is below the required '
            || to_varchar(
                case metric_name
                    when 'answer_correctness'  then {{ min_correctness }}
                    when 'logical_consistency' then {{ min_consistency }}
                    else 0
                end
            ) as detail
    from current_scores
    where metric_name in ('answer_correctness', 'logical_consistency')
    group by metric_name
    having avg(eval_agg_score) <
        case metric_name
            when 'answer_correctness'  then {{ min_correctness }}
            when 'logical_consistency' then {{ min_consistency }}
            else 0
        end

),

-- Check 2 — nothing that used to pass now fails.
--
-- Joined on the input text rather than record_id, because record ids are per-run
-- and the same question is a different record each time. Compared with a small
-- tolerance so that ordinary judge jitter does not read as a regression; the
-- threshold check above is what catches a genuine broad decline.
{% if previous_run %}
regressions as (

    select
        'REGRESSION' as failure,
        c.metric_name
            || ' fell from '
            || to_varchar(round(b.eval_agg_score, 3))
            || ' to '
            || to_varchar(round(c.eval_agg_score, 3))
            || ' on: '
            || left(c.input, 120) as detail
    from current_scores  c
    join baseline_scores b
        on  c.input = b.input
        and c.metric_name = b.metric_name
    where b.eval_agg_score >= {{ var('eval_regression_was_passing_at', 0.7) }}
      and c.eval_agg_score <  b.eval_agg_score - {{ var('eval_regression_tolerance', 0.2) }}

),
{% endif %}

-- Check 3 — scores actually exist. See the vacuous-pass note above.
emptiness as (

    select
        'NO_SCORES' as failure,
        'Run {{ current_run }} returned no scored records. Nothing was graded.' as detail
    from (select 1)
    where (select count(*) from current_scores) = 0

)

select failure, detail from threshold_failures
union all
select failure, detail from emptiness
{% if previous_run %}
union all
select failure, detail from regressions
{% endif %}

{%- endif -%}
