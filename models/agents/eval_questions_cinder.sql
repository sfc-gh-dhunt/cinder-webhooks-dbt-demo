{{
    config(
        materialized='table',
        schema='SEMANTIC'
    )
}}

/*
    Evaluation dataset source for the Cinder moderation agent.

    WHY THIS MODEL EXISTS AT ALL, rather than pointing the evaluation straight at
    the seed. Ground truth has to be a VARIANT holding a JSON object, because
    `answer_correctness` reads a `ground_truth_output` key out of it. A dbt seed
    cannot carry a VARIANT — the same reason the raw event payloads are seeded as
    VARCHAR and PARSE_JSON'd in the base layer. So the seed holds reviewable
    prose in flat columns and this model assembles the shape the evaluator wants.

    Keeping the prose flat in the seed is the point: a reviewer can read a diff
    of the questions and expected answers in a pull request without reading JSON.

    TO_VARIANT IS NOT DECORATION. OBJECT_CONSTRUCT returns OBJECT, not VARIANT,
    and the documentation is explicit that the column type must be VARIANT. Drop
    the cast and the dataset builds but the metric has nothing to read.

    ON WRITING GROUND TRUTH. The value is fed to an LLM judge as a rubric, not
    string-compared, so it should read as instructions to a careful reviewer:
    the expected value where one is stable, the tolerance, the units, and what a
    wrong-but-plausible answer would look like. The seeded text is deliberately
    written that way.

    Absolute dates matter. The documented failure mode is ground-truth staleness:
    "what was revenue last quarter" drifts as time passes and the answer silently
    stops matching, whereas a question scoped to a fixed window stays gradeable.
    The seeded questions avoid relative windows for that reason.

    THE `semantic_model` COLUMN IS NOT USED YET, and is here on purpose. It
    records which semantic view each question exercises. Today every row says
    sem_cinder_moderation and the whole set runs together. When this agent grows
    a second Cortex Analyst tool over a second semantic view, that column is what
    lets one eval model filter to its own subset — so adding per-view evals later
    is a WHERE clause and a new model, not a reshaping of the dataset. Cheap to
    carry now, expensive to retrofit.
*/

select
    question_id,
    semantic_model,
    query_text,

    -- The VARIANT the evaluator reads. Only `ground_truth_output` is populated:
    -- `answer_correctness` is the metric using it, and `logical_consistency` is
    -- reference-free and reads nothing here.
    --
    -- `ground_truth_invocations` would go alongside it for the tool-selection and
    -- tool-execution metrics, which are Public Preview. They are omitted rather
    -- than commented in, because a gate should not depend on preview metrics.
    to_variant(object_construct('ground_truth_output', ground_truth)) as ground_truth

from {{ ref('cinder_agent_eval_questions') }}
