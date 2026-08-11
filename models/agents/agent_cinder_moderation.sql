{{
    config(
        materialized='cortex_agent',
        profile={'display_name': 'Cinder Moderation Analyst', 'color': 'blue'},
        agent_comment='Trust & Safety moderation analyst over the Cinder marts. Managed by dbt — do not edit in Snowsight.',
        version_comment='cinder_webhooks dbt deploy'
    )
}}

{#-
    ===========================================================================
    Cinder moderation agent — a Cortex Agent, in version control, in the DAG
    ===========================================================================
    THE MODEL BODY IS THE AGENT SPECIFICATION. Everything below the Jinja is
    YAML handed verbatim to `FROM SPECIFICATION` / `SET SPECIFICATION` by
    macros/materializations/cortex_agent.sql. There is no transformation.

    WHY THE AGENT IS A dbt MODEL AT ALL, given that Snowflake documents agent
    management through SQL, the REST API and Snowsight rather than as a dbt
    object. The reason is not the DDL — issuing `CREATE AGENT` from a shell
    script is not hard. It is DEPENDENCY ORDERING.

    `{{ ref('sem_cinder_moderation') }}` below does two things at once: it
    resolves to the fully-qualified semantic view name, and it makes the agent a
    child of the semantic view in the dbt graph. So dbt cannot build this agent
    before the semantic view it points at, and cannot build the semantic view
    before the marts underneath it. The whole chain moves in one commit and
    fails as a unit.

    That matters more than it sounds, because of how agents fail. An agent whose
    spec names a semantic view that does not exist yet does not error loudly —
    `ALTER AGENT ... SET SPECIFICATION` replaces the whole spec and takes what
    it is given. Ordering is the thing preventing a deploy from producing a
    syntactically valid agent pointing at nothing. A bash script gives you no
    such guarantee; the DAG does.

    The second thing it buys is selection. Because the eval model refs this
    agent and this agent refs the semantic view, `dbt build -s
    sem_cinder_moderation+` means "the semantic view, the agent on top of it,
    and the evals that grade it" without anybody maintaining that list. See
    models/agents/eval_cinder_moderation.sql.

    WHAT THIS DELIBERATELY DOES NOT CONFIGURE: aliases. Promotion to a
    `production` alias is a pipeline decision, not a transform decision — a
    `dbt run` on a laptop should not be able to change what production serves.
    The materialization moves DEFAULT_VERSION and stops there.

    IF YOU EDIT THIS AGENT IN SNOWSIGHT, YOUR CHANGES WILL BE OVERWRITTEN on the
    next deploy, and worse, pressing Publish there pins DEFAULT_VERSION and
    silently breaks the implicit "newest version is served" behaviour. The
    materialization re-asserts DEFAULT_VERSION on every run specifically to heal
    that, but the spec edit itself is lost. Git is the source of truth.
-#}

models:
  orchestration: "auto"

orchestration: {}

instructions:
  response: |
    You are a Trust & Safety analyst for a content moderation operation.

    Answer with numbers from the semantic view, and name the grain you counted
    at. If a question is ambiguous between grains — "how many violations" could
    mean decisions or policy applications — say which you used and why.

    Three things about this data that will otherwise make you wrong:

    * Do not sum decision counts from policy applications. A decision that
      applied three policies appears three times there. Use the allocated
      fractional count when a distribution must add up to the decision total,
      and the raw count when the question is how often a policy is applied.

    * Automated decisions and workflow-driven actions have no human actor. They
      are absent from the reviewer dimension by design, so per-reviewer metrics
      cover human work only. Say so when it matters to the answer.

    * A job that closes with zero decisions produces no closure event, so it
      looks permanently open. "Open" means "no closure seen", not "still in a
      queue". Flag this if someone asks about open job counts.

    If the data cannot answer the question, say what is missing rather than
    substituting a proxy.

  sample_questions:
    - "What is the automation rate this month, and how has it moved?"
    - "Which queues have the longest median handle time?"
    - "Show the policy distribution for violating outcomes, as a share of decisions."
    - "How many jobs were escalated before closing, and who escalated them?"
    - "Which moderators handled the most jobs last week?"

tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "cinder_moderation"
      description: |
        Moderation analytics for a Trust & Safety operation: jobs, decisions,
        applied policies, queue movements, reviewers, queues, entities and
        enforcement actions. Use for anything about moderation volume, handle
        time, automation share, policy distribution, escalation or reviewer
        activity.

tool_resources:
  cinder_moderation:
    {#- The load-bearing line. Resolves to the FQN and creates the DAG edge. -#}
    semantic_view: {{ ref('sem_cinder_moderation') }}
