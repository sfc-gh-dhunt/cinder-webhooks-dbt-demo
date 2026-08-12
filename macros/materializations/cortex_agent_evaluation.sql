{#-
    =========================================================================
    cortex_agent_evaluation — run a Cortex Agent evaluation from a dbt model
    =========================================================================
    The model body IS the `EXECUTE_AI_EVALUATION` run-configuration YAML. This
    materialization stages it and, when asked, starts a run and waits for it.

    ############################################################################
    # THE SPLIT THAT MATTERS: THIS RUNS THE EVAL, A TEST ASSERTS IT            #
    ############################################################################
    Running an evaluation is a paid, slow, non-deterministic operation: the agent
    is invoked once per dataset row, then an LLM judge scores each metric on each
    row. Asserting that the resulting scores clear a threshold is free, fast and
    deterministic.

    Those are different things and they belong in different dbt objects. So this
    materialization produces scores, and tests/assert_agent_eval_scores.sql
    grades them. Consequences worth having:

      * A flaky judge run can be re-graded without re-spending credits.
      * The threshold lives in test config, so tightening it is not a code change
        to a materialization.
      * `dbt test` alone answers "is the agent still good enough", which is
        exactly what a pull-request check wants to ask.

    The alternative — making the whole eval a test — conflates a paid async job
    with an assertion, and makes every re-check cost money.

    ############################################################################
    # COST IS THE REASON `eval_run` DEFAULTS TO FALSE                          #
    ############################################################################
    A plain `dbt run` keeps the staged config in sync and does NOT start a run.
    That is free. Starting a run costs credits proportional to (rows x metrics),
    every time, plus warehouse time for the tasks and metric queries.

    So paid runs are deliberate:

        dbt build --select agent_cinder_moderation+ --vars '{eval_run: true}'

    There is no official cost guidance for evaluating at pull-request frequency.
    Keep the dataset small enough that a run per PR is affordable, and grow it
    only alongside a decision about who pays.

    ############################################################################
    # FIVE THINGS ABOUT THIS SURFACE THAT WILL OTHERWISE COST YOU AN AFTERNOON #
    ############################################################################

    1. `EXECUTE_AI_EVALUATION` IGNORES A FULLY-QUALIFIED `agent_name` in the YAML
       and resolves the agent from SESSION CONTEXT. The documentation is explicit
       that with SQL, evaluations run on the session's database and schema. That
       is a live CI hazard — a pipeline whose session context differs from the
       agent's location silently evaluates a different agent or fails obscurely.
       So this materialization sets session context EXPLICITLY before calling,
       rather than trusting the config.

    2. REUSING A DATASET NAME FAILS. If the YAML carries a `dataset:` block,
       Snowflake tries to CREATE that dataset on every run and errors once it
       exists, even when only `run_name` changed. The documented pattern for
       repeated runs is to drop the `dataset:` block and reference the existing
       dataset through `evaluation.source_metadata`.

       So the model body deliberately has NO `dataset:` block. This
       materialization checks whether the dataset exists and prepends one only
       when it does not. Both are top-level YAML keys, so prepending is a
       concatenation rather than a parse-and-rewrite.

       Note the RUN name must be unique per run while the DATASET name must be
       stable. Those are opposite requirements, and conflating them is precisely
       what triggers the failure above.

    3. GROUND TRUTH IS VARIANT JSON, NOT TEXT. `answer_correctness` reads a
       `ground_truth_output` key out of a VARIANT. A dbt seed cannot carry a
       VARIANT, so models/agents/eval_questions_cinder.sql wraps the seeded prose
       with OBJECT_CONSTRUCT and that model is the dataset source.

    4. THE STATUS VALUES ARE NOT WHAT YOU WOULD GUESS. There is no FAILED. The
       terminal states are COMPLETED, PARTIALLY_COMPLETED and CANCELLED.
       Critically, INVOCATION_COMPLETED is NOT terminal — metric computation runs
       after it, so stopping there reads scores that do not exist yet and the
       grading test passes vacuously. That is the worst available failure for a
       gate, so the poll below waits for genuinely terminal states only.

    5. THE FILE FORMAT IS NOT OPTIONAL. The config is written with CSV, no field
       delimiter, no enclosing character and no escaping, matching what Snowflake
       documents for these files. Default CSV settings quote and escape the
       content into something that is no longer valid YAML, and it surfaces much
       later as an unhelpful config error rather than a write failure.

    CONFIG
      materialized='cortex_agent_evaluation'  required
      dataset_name='...'                      required; schema-level object name
      eval_source_model='<model name>'         required until the dataset exists
      query_column='query_text'               optional
      ground_truth_column='ground_truth'      optional
      eval_stage='<db>.<schema>.<stage>'      optional; created if absent
      run_name_prefix='...'                   optional
      poll_seconds=15 / poll_attempts=40      optional; wait budget
-#}

{% materialization cortex_agent_evaluation, adapter='snowflake' -%}

    {%- set eval_config = sql -%}

    {%- if '$$' in eval_config -%}
        {%- do exceptions.raise_compiler_error(
            "Eval config for '" ~ model.name ~ "' contains '$$', which terminates the literal."
        ) -%}
    {%- endif -%}

    {%- set stage_fqn = config.get(
            'eval_stage', this.database ~ '.' ~ this.schema ~ '.CORTEX_EVAL_CONFIGS'
    ) -%}
    {%- set run_prefix = config.get('run_name_prefix', model.name) -%}
    {%- set poll_seconds = config.get('poll_seconds', 15) -%}
    {%- set poll_attempts = config.get('poll_attempts', 40) -%}
    {%- set source_model = config.get('eval_source_model', none) -%}
    {#- Resolved HERE, not in the model's config block. `ref()` inside `config()` does
        not resolve to the referenced relation — it yielded the calling model's own
        relation instead, so the dataset was pointed at the evaluation model:

            Object 'CINDER_ANALYTICS.PR6_SEMANTIC.EVAL_CINDER_MODERATION'
            does not exist or not authorized

        Stringifying it did not help either; it has to be resolved in the
        materialization, where ref() behaves. The model body still carries a
        `do ref()` for the DAG edge. -#}
    {%- set source_table = ref(source_model) if source_model else none -%}
    {%- set dataset_name = config.get('dataset_name', none) -%}
    {%- set query_column = config.get('query_column', 'query_text') -%}
    {%- set gt_column = config.get('ground_truth_column', 'ground_truth') -%}

    {%- if dataset_name is none -%}
        {%- do exceptions.raise_compiler_error(
            "Model '" ~ model.name ~ "' needs a dataset_name config."
        ) -%}
    {%- endif -%}

    {%- set run_name = run_prefix ~ '_' ~ (invocation_id | replace('-', ''))[:12] -%}
    {%- set config_file = model.name ~ '.yaml' -%}
    {%- set should_run = var('eval_run', false) -%}

    {%- set original_query_tag = set_query_tag() -%}

    {%- call statement('main') -%}
        select 1 as eval_materialization_placeholder
    {%- endcall -%}

    {% if execute %}

        {#- Step 1 — stage. Internal, because the config is build output rather
            than something to manage by hand. -#}
        {%- do run_query("create stage if not exists " ~ stage_fqn) -%}

        {#- Step 2 — dataset. Prepend a creation block only when absent. -#}
        {%- set existing_ds = run_query(
            "show datasets like '" ~ dataset_name ~ "' in schema "
            ~ this.database ~ "." ~ this.schema
        ) -%}

        {%- if existing_ds | length == 0 -%}
            {%- if source_table is none -%}
                {%- do exceptions.raise_compiler_error(
                    "Dataset '" ~ dataset_name ~ "' does not exist and no eval_source_model "
                    ~ "is configured on '" ~ model.name ~ "', so it cannot be created."
                ) -%}
            {%- endif -%}
            {%- do log("Dataset " ~ dataset_name ~ " absent — prepending a dataset block", info=true) -%}
            {%- set dataset_block = 'dataset:\n  dataset_type: "CORTEX AGENT"\n  table_name: "'
                ~ source_table ~ '"\n  dataset_name: "' ~ dataset_name
                ~ '"\n  column_mapping:\n    query_text: "' ~ query_column
                ~ '"\n    ground_truth: "' ~ gt_column ~ '"\n\n' -%}
            {%- set eval_config = dataset_block ~ eval_config -%}
        {%- else -%}
            {%- do log("Dataset " ~ dataset_name ~ " exists — referencing it, not recreating", info=true) -%}
        {%- endif -%}

        {#- Step 3 — write the config. OVERWRITE because git is its source. -#}
        {%- set write_sql -%}
            copy into @{{ stage_fqn }}/{{ config_file }}
            from (select $${{ eval_config }}$$)
            file_format = (
                type = csv
                field_delimiter = none
                record_delimiter = '\n'
                skip_header = 0
                field_optionally_enclosed_by = none
                escape_unenclosed_field = none
                compression = none
            )
            single = true
            overwrite = true
            header = false
        {%- endset -%}
        {%- do run_query(write_sql) -%}
        {%- do log("Staged eval config at @" ~ stage_fqn ~ "/" ~ config_file, info=true) -%}

        {%- if not should_run -%}

            {%- do log(
                "Eval config for " ~ model.name ~ " staged but NOT run (a run costs credits). "
                ~ "Run it with: dbt build --select " ~ model.name ~ " --vars '{eval_run: true}'",
                info=true
            ) -%}

        {%- else -%}

            {#- Step 4 — session context, explicitly. See note 1. -#}
            {%- do run_query("use schema " ~ this.database ~ "." ~ this.schema) -%}

            {%- do log("Starting evaluation run " ~ run_name, info=true) -%}
            {%- do run_query(
                "call execute_ai_evaluation('START', object_construct('run_name', '"
                ~ run_name ~ "'), '@" ~ stage_fqn ~ "/" ~ config_file ~ "')"
            ) -%}

            {#- Step 5 — wait for a genuinely terminal state. See note 4. -#}
            {%- set ns = namespace(done=false, final='UNKNOWN') -%}
            {%- for attempt in range(poll_attempts) -%}
                {%- if not ns.done -%}
                    {%- set status = run_query(
                        "call execute_ai_evaluation('STATUS', object_construct('run_name', '"
                        ~ run_name ~ "'), '@" ~ stage_fqn ~ "/" ~ config_file ~ "')"
                    ) -%}
                    {%- set state = 'UNKNOWN' -%}
                    {%- set details = '' -%}
                    {%- for row in status -%}
                        {%- if 'STATUS' in status.column_names -%}
                            {%- set state = row['STATUS'] | string | upper -%}
                        {%- elif 'status' in status.column_names -%}
                            {%- set state = row['status'] | string | upper -%}
                        {%- endif -%}
                        {%- if 'STATUS_DETAILS' in status.column_names -%}
                            {%- set details = row['STATUS_DETAILS'] | string -%}
                        {%- elif 'status_details' in status.column_names -%}
                            {%- set details = row['status_details'] | string -%}
                        {%- endif -%}
                    {%- endfor -%}

                    {#- FAIL FAST ON A REPORTED ERROR. `STATUS_DETAILS` carries the
                        run's error messages, and a run whose agent invocations all
                        failed does NOT necessarily reach a terminal status \u2014 the
                        first time this happened the loop polled a dead run for the
                        full fifteen-minute budget and then reported a timeout, which
                        says nothing about the cause. The real error was sitting in
                        this field the whole time.

                        Surfacing it here turns fifteen minutes and a shrug into
                        seconds and a diagnosis. -#}
                    {%- if details and details not in ['[]', 'None', ''] -%}
                        {%- do exceptions.raise_compiler_error(
                            "Evaluation run " ~ run_name ~ " reported errors (status "
                            ~ state ~ "): " ~ details
                            ~ " -- this is a harness or agent failure, not a score failure."
                        ) -%}
                    {%- endif -%}

                    {%- if state in ['COMPLETED', 'PARTIALLY_COMPLETED', 'CANCELLED'] -%}
                        {%- set ns.done = true -%}
                        {%- set ns.final = state -%}
                    {%- else -%}
                        {%- do run_query("select system$wait(" ~ poll_seconds ~ ")") -%}
                    {%- endif -%}
                {%- endif -%}
            {%- endfor -%}

            {#- A harness failure is NOT a quality failure, and conflating them
                makes a red build unreadable. Raise on CANCELLED and on timeout,
                so the pipeline says "the eval did not run" rather than letting
                the grading test report "the agent is bad" on no data. -#}
            {%- if ns.final == 'CANCELLED' -%}
                {%- do exceptions.raise_compiler_error(
                    "Evaluation run " ~ run_name ~ " was CANCELLED. Harness failure, not a score failure."
                ) -%}
            {%- elif not ns.done -%}
                {%- do exceptions.raise_compiler_error(
                    "Evaluation run " ~ run_name ~ " did not reach a terminal state within "
                    ~ (poll_seconds * poll_attempts) ~ "s. Raise poll_attempts, or inspect the run in Snowsight."
                ) -%}
            {%- elif ns.final == 'PARTIALLY_COMPLETED' -%}
                {#- Some records scored, some did not. Deliberately NOT a raise:
                    the grading test can still judge what landed, and failing here
                    would turn a partial judge outage into a red build with no
                    scores to look at. Loud log; the test decides. -#}
                {%- do log(
                    "WARNING: run " ~ run_name ~ " is PARTIALLY_COMPLETED — some records did not "
                    ~ "score. Grading will proceed on a partial result set.", info=true
                ) -%}
            {%- endif -%}

            {#- Step 6 — record which run this was, so the grading test does not
                have to guess. Guessing picks up another pull request's run. -#}
            {%- set runs_table = this.database ~ '.' ~ this.schema ~ '.' ~ model.name ~ '__runs' -%}
            {%- do run_query(
                "create table if not exists " ~ runs_table ~ " ("
                ~ "run_name varchar, agent_database varchar, agent_schema varchar, "
                ~ "agent_name varchar, run_status varchar, invocation_id varchar, "
                ~ "created_at timestamp_ntz)"
            ) -%}
            {%- do run_query(
                "insert into " ~ runs_table ~ " select "
                ~ "'" ~ run_name ~ "', "
                ~ "'" ~ config.get('agent_database', this.database) ~ "', "
                ~ "'" ~ config.get('agent_schema', this.schema) ~ "', "
                ~ "'" ~ config.get('agent_name', '') ~ "', "
                ~ "'" ~ ns.final ~ "', "
                ~ "'" ~ invocation_id ~ "', current_timestamp()::timestamp_ntz"
            ) -%}

            {%- do log("Evaluation run " ~ run_name ~ " finished: " ~ ns.final, info=true) -%}

        {%- endif -%}

    {% endif %}

    {%- do unset_query_tag(original_query_tag) -%}

    {%- do return({'relations': [this.incorporate(type='view')]}) -%}

{%- endmaterialization %}
