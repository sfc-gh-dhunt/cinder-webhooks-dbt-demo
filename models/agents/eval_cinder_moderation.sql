{{
    config(
        materialized='cortex_agent_evaluation',
        schema='SEMANTIC',
        dataset_name='CINDER_AGENT_EVAL_SET',
        eval_source_table=ref('eval_questions_cinder') | string,
        agent_name='agent_cinder_moderation',
        run_name_prefix='cinder_moderation_pr',
        poll_seconds=15,
        poll_attempts=60
    )
}}

{#-
    ===========================================================================
    Evaluation run configuration for the Cinder moderation agent
    ===========================================================================
    THE MODEL BODY IS THE `EXECUTE_AI_EVALUATION` RUN CONFIG. It is staged and
    optionally executed by macros/materializations/cortex_agent_evaluation.sql.

    A PLAIN `dbt run` DOES NOT START A RUN. It keeps the staged config in sync,
    which is free. Starting a run invokes the agent once per question and then an
    LLM judge once per metric per question, and that costs credits every time:

        dbt build --select agent_cinder_moderation+ --vars '{eval_run: true}'

    THERE IS DELIBERATELY NO `dataset:` BLOCK HERE, and its absence is the whole
    trick. If the YAML carries one, Snowflake tries to CREATE that dataset on
    every run and fails once it already exists — even when only the run name
    changed. The documented pattern for repeated runs against a stable dataset is
    to reference it through `source_metadata` and omit the creation block, which
    is what this does. The materialization prepends a `dataset:` block on the
    first run only, when it finds the dataset missing.

    Note the two names pull in opposite directions and must not be conflated:
    the RUN name has to be unique per run, the DATASET name has to be stable.
    The materialization derives the run name from dbt's invocation id.

    THE TWO `ref()`s BELOW ARE WHY THIS WORKS AS A GATE.

      * `ref('agent_cinder_moderation')` makes this eval a child of the agent, so
        dbt cannot grade a version it has not deployed. Without it the eval could
        run first and score the previous spec — passing a gate on the wrong
        artifact, which is worse than no gate.
      * `ref('eval_questions_cinder')` makes it a child of the dataset, so the
        questions exist before anything reads them.

    Together they mean `dbt build --select sem_cinder_moderation+` selects the
    semantic view, the agent above it, and the evals that grade it, without
    anybody maintaining that list. Change a mart column and the chain that could
    be broken by it is exactly the chain that rebuilds and re-grades.

    METRIC CHOICE IS CONSTRAINED, NOT PREFERENTIAL.

      * `answer_correctness` — GA. Reads `ground_truth_output` from the dataset's
        VARIANT and compares it to the streamed reply.
      * `logical_consistency` — GA and REFERENCE-FREE. It needs no ground truth
        at all, which makes it the cheapest useful signal to add: it checks the
        agent's instructions, planning and tool calls are consistent with each
        other, and it catches a confidently wrong answer that a correctness
        rubric might wave through.

    `tool_selection_accuracy` and `tool_execution_accuracy` are Public Preview
    and are OMITTED ON PURPOSE. They would be genuinely useful here — this agent
    has exactly one tool, so tool selection is close to a tautology today, but it
    stops being one the moment a second tool lands. Gating a pull request on a
    preview metric means a preview change can turn every build red. Add them when
    they go GA; that is the only thing blocking them.

    A custom metric would go in this same list as a mapping with `name`,
    `score_ranges` and `prompt`. None is defined yet. The obvious candidate for
    this domain is a check that the answer names the grain it counted at, since
    that is the failure the instructions work hardest to prevent.
-#}

{#- ---------------------------------------------------------------------------
    DAG EDGES, DECLARED EXPLICITLY.

    This model body is YAML, not SQL, so there is no natural place for a `ref()`
    to appear in the rendered output the way there is in a normal model. A `ref()`
    written inside a Jinja COMMENT does not count — comments are stripped without
    being evaluated, so the dependency is silently never registered and the eval
    becomes an orphan node that dbt is free to run before the agent exists.

    That is a real trap: the eval would still "work", and would grade whatever
    version of the agent happened to be deployed last time. A gate that passes on
    the wrong artifact is worse than no gate.

    `do ref(...)` registers the dependency and emits nothing into the YAML.

    ---------------------------------------------------------------------------
    NO JINJA COMMENTS INSIDE THE YAML BLOCK BELOW. This body is whitespace-
    sensitive YAML, and a Jinja comment whose delimiters carry the whitespace-trim
    marker eats the newline and
    indentation around it — which silently welds two keys together:

        agent_params:agent_name: "agent_cinder_moderation"

    The resulting error arrives from inside EXECUTE_AI_EVALUATION as a YAML block
    mapping complaint about a line number that does not correspond to anything in
    this file, because it refers to the RENDERED string. It cost a CI round trip.

    So all commentary lives up here, and the YAML below stays bare.

    ON `agent_name` BEING UNQUALIFIED: that is not an oversight.
    EVERY NAME BELOW IS FULLY QUALIFIED, and that is a correction rather than a
    preference. Both the agent and the dataset are documented as resolving relative
    to the session's database and schema, so the first attempt set session context
    explicitly with `use schema` and left the names bare.

    That does not survive Snowflake-native dbt. Each statement the materialization
    issues gets its own context, so the `use schema` had no effect on the later
    call and resolution fell back to the profile's schema:

        Failed to validate query_text: Schema 'CINDER_ANALYTICS.PUBLIC'
        does not exist or not authorized

    which is doubly confusing because it blames query_text for a schema problem,
    and because the dataset had in fact been created — just in the pull request's
    schema, while the lookup went to PUBLIC. The documentation permits a fully
    qualified name for the agent, so use one, and derive both from `this` so the
    same code works in production and inside a per-pull-request schema.

    The materialization still sets session context. It is now belt and braces
    rather than the mechanism.
--------------------------------------------------------------------------- -#}
{%- do ref('eval_questions_cinder') -%}

evaluation:
  agent_params:
    agent_name: "{{ this.database }}.{{ this.schema }}.{{ ref('agent_cinder_moderation').identifier }}"
    agent_type: "CORTEX AGENT"
  run_params:
    label: "cinder moderation gate"
    description: "Automated evaluation of the Cinder moderation agent, run from dbt."
  source_metadata:
    type: "dataset"
    dataset_name: "{{ this.database }}.{{ this.schema }}.CINDER_AGENT_EVAL_SET"

metrics:
  - "answer_correctness"
  - "logical_consistency"
