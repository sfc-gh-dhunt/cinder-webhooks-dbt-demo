{{
    config(
        materialized='semantic_view',
        copy_grants=true
    )
}}

/*
    Semantic view over the Cinder moderation marts, for Cortex Analyst.

    THE MODEL BODY IS THE DDL. Everything below is placed directly after
    CREATE OR REPLACE SEMANTIC VIEW by the dbt_semantic_view package — there is no
    transformation. That is what puts the semantic layer in version control and in the same
    DAG as the marts feeding it: a column rename in a mart and the semantic view that
    exposes it move together, in one commit, and dbt refuses to build them out of order.

    WHY EACH FACT IS SEPARATE, AND WHY THAT MATTERS TO WHOEVER ASKS THE QUESTIONS.
    Four facts at four grains. A job closes once, is decided one or more times, applies one
    or more policies per decision, and is actioned many times. Collapsing those into one
    wide table would make "average handle time" quietly wrong, because a job with three
    queue changes would contribute its handle time three times. Keeping them apart means
    each measure is summed only from the grain where it is true.

    SYNONYMS ARE IN THE LANGUAGE OF THE ROOM, not the language of the schema. Nobody asks
    about `reviewer_email`; they ask about moderators. The synonyms below are the vocabulary
    a Trust & Safety team actually uses, which is the difference between Cortex Analyst
    answering the question and Cortex Analyst asking what you meant.
*/

TABLES (

    -- One row per job, open or closed. The accumulating snapshot, and the only place the
    -- cross-event lifecycle measures exist.
    jobs AS {{ ref('fct_jobs') }}
        PRIMARY KEY (job_key)
        WITH SYNONYMS = ('jobs', 'review jobs', 'moderation jobs', 'tasks', 'cases')
        COMMENT = 'One row per moderation job, whether or not it has closed',

    -- One row per decision on a closed job.
    decisions AS {{ ref('fct_decisions') }}
        PRIMARY KEY (decision_sk)
        WITH SYNONYMS = ('decisions', 'moderation decisions', 'verdicts', 'outcomes')
        COMMENT = 'One row per decision recorded on a closed job',

    -- One row per decision per applied policy.
    decision_policies AS {{ ref('fct_decision_policies') }}
        PRIMARY KEY (decision_policy_sk)
        WITH SYNONYMS = ('policy applications', 'policy violations', 'applied policies')
        COMMENT = 'One row per decision per applied policy — the grain for policy distribution',

    -- One row per job lifecycle movement.
    job_actions AS {{ ref('fct_job_actions') }}
        PRIMARY KEY (job_action_event_sk)
        WITH SYNONYMS = ('job actions', 'queue movements', 'job activity', 'moderator activity')
        COMMENT = 'One row per job lifecycle movement — escalations, queue changes, skips',

    queues AS {{ ref('dim_queue') }}
        PRIMARY KEY (queue_key)
        UNIQUE (queue_slug)
        WITH SYNONYMS = ('queues', 'review queues', 'inboxes', 'work queues')
        COMMENT = 'Review queues, observed from activity',

    policies AS {{ ref('dim_policy') }}
        PRIMARY KEY (policy_key)
        WITH SYNONYMS = ('policies', 'violation types', 'rules', 'policy tree')
        COMMENT = 'Moderation policies with parent hierarchy',

    reviewers AS {{ ref('dim_reviewer') }}
        PRIMARY KEY (reviewer_key)
        UNIQUE (reviewer_email)
        WITH SYNONYMS = ('moderators', 'reviewers', 'agents', 'analysts', 'staff')
        COMMENT = 'Human moderators. Automated decisions have no reviewer by design',

    entities AS {{ ref('dim_entity') }}
        PRIMARY KEY (entity_key)
        WITH SYNONYMS = ('entities', 'content', 'items', 'objects under review')
        COMMENT = 'Entities under review — accounts, posts, images and other schemas'

)

RELATIONSHIPS (

    -- Each fact joins to the dimensions it needs. Policy applications reach queue and
    -- moderator THROUGH the decision rather than directly, so there is exactly one join
    -- path between any pair of tables — two paths would leave the aggregation ambiguous and
    -- the answers unstable.
    jobs_to_queues AS jobs (final_queue_key) REFERENCES queues (queue_key),
    jobs_to_entities AS jobs (entity_key) REFERENCES entities (entity_key),
    jobs_to_reviewers AS jobs (final_reviewer_key) REFERENCES reviewers (reviewer_key),

    decisions_to_queues AS decisions (queue_key) REFERENCES queues (queue_key),
    decisions_to_reviewers AS decisions (reviewer_key) REFERENCES reviewers (reviewer_key),
    decisions_to_entities AS decisions (entity_key) REFERENCES entities (entity_key),

    decision_policies_to_decisions AS decision_policies (decision_sk) REFERENCES decisions (decision_sk),
    decision_policies_to_policies AS decision_policies (policy_key) REFERENCES policies (policy_key),

    job_actions_to_queues AS job_actions (queue_key) REFERENCES queues (queue_key),
    job_actions_to_reviewers AS job_actions (reviewer_key) REFERENCES reviewers (reviewer_key),
    job_actions_to_entities AS job_actions (entity_key) REFERENCES entities (entity_key)

)

FACTS (

    -- Row-level values that metrics aggregate. Declared as facts rather than dimensions so
    -- Cortex Analyst does not offer to group by a duration.
    jobs.job_time_to_close_hours AS jobs.time_to_close_hours,
    jobs.job_handle_time_hours AS jobs.handle_time_hours,
    jobs.job_queue_changes AS jobs.queue_change_count,
    jobs.job_actions_taken AS jobs.action_count,
    jobs.job_decisions_taken AS jobs.decision_count,
    jobs.job_wait_time_hours AS jobs.time_to_first_action_seconds / 3600.0,
    jobs.job_post_decision_lag_hours AS jobs.decision_to_close_seconds / 3600.0,

    decisions.decision_handle_time_hours AS decisions.handle_time_hours,
    decisions.decision_enforcement_actions AS decisions.enforcement_action_count,
    decisions.decision_policies_applied AS decisions.policy_count,

    job_actions.action_job_age_hours AS job_actions.job_age_at_action_hours,

    decision_policies.policy_allocated_decisions AS decision_policies.decision_count_allocated

)

DIMENSIONS (

    -- ---- Queue ---------------------------------------------------------------------
    queues.queue_name AS queues.queue_name
        WITH SYNONYMS = ('queue', 'queue name', 'inbox', 'review queue')
        COMMENT = 'Readable queue name',
    queues.queue_slug AS queues.queue_slug
        WITH SYNONYMS = ('queue slug', 'queue id')
        COMMENT = 'Queue identifier as it appears in Cinder',
    queues.queue_is_multi_review AS queues.queue_is_multi_review
        WITH SYNONYMS = ('multi review queue', 'requires multiple reviews', 'double review')
        COMMENT = 'Whether the queue requires more than one review',

    -- ---- Policy --------------------------------------------------------------------
    policies.policy_name AS policies.policy_name
        WITH SYNONYMS = ('policy', 'policy name', 'violation', 'violation type', 'rule')
        COMMENT = 'Specific policy applied',
    policies.policy_area AS policies.policy_group_name
        WITH SYNONYMS = ('policy area', 'policy group', 'parent policy', 'policy category', 'harm area')
        COMMENT = 'Parent policy area. Prefer this over policy name for distribution — leaf-level policies fragment into unreadably thin slices',
    policies.policy_severity_class AS policies.policy_severity_class
        WITH SYNONYMS = ('severity', 'policy severity', 'illegal or violating', 'harm class')
        COMMENT = 'One of illegal, violating, non_violating. A non-violating policy records a reviewed-and-cleared outcome, not a violation',
    policies.policy_is_illegal AS policies.policy_is_illegal
        WITH SYNONYMS = ('illegal', 'illegal content', 'legally reportable')
        COMMENT = 'Whether the policy covers illegal content',

    -- ---- Moderator -----------------------------------------------------------------
    reviewers.moderator_name AS reviewers.reviewer_name
        WITH SYNONYMS = ('moderator', 'moderator name', 'reviewer', 'agent', 'who decided')
        COMMENT = 'Moderator display name',
    reviewers.moderator_email AS reviewers.reviewer_email
        WITH SYNONYMS = ('moderator email', 'reviewer email', 'agent email')
        COMMENT = 'Moderator email — the business key, since the webhooks carry no user id',
    reviewers.staffing_model AS reviewers.staffing_model
        WITH SYNONYMS = ('reviewer staffing', 'reviewer vendor', 'reviewer team')
        COMMENT = 'Vendor name for outsourced moderators, otherwise In-house. Covers HUMAN reviewers only — for a breakdown that includes automated decisions, use decision_staffing_model instead',
    reviewers.moderator_is_outsourced AS reviewers.is_outsourced
        WITH SYNONYMS = ('outsourced', 'is BPO', 'external moderator')
        COMMENT = 'Whether the moderator belongs to an outsourced vendor team',
    reviewers.moderator_is_qa AS reviewers.is_qa
        WITH SYNONYMS = ('QA', 'quality assurance', 'auditor')
        COMMENT = 'Whether the moderator is in the QA group',

    -- ---- Entity --------------------------------------------------------------------
    entities.entity_type AS entities.entity_schema
        WITH SYNONYMS = ('entity type', 'content type', 'object type', 'what was reviewed')
        COMMENT = 'Entity schema — user, text_post, image_post and any customer-defined schema',

    -- ---- Job ----------------------------------------------------------------------
    jobs.job_status AS jobs.job_status
        WITH SYNONYMS = ('status', 'job status', 'open or closed', 'state')
        COMMENT = 'closed when a closure event was seen, otherwise the latest action status',
    jobs.job_category AS jobs.job_category
        WITH SYNONYMS = ('job category', 'job type', 'work type', 'appeal or standard')
        COMMENT = 'Job category — standard, appeal, qa, golden and others',
    jobs.job_is_closed AS jobs.is_closed
        WITH SYNONYMS = ('closed', 'is closed', 'resolved')
        COMMENT = 'Whether a closure event was seen for this job',
    jobs.job_closed_by_automation AS jobs.closed_by_automated_decision
        WITH SYNONYMS = ('closed automatically', 'automated close', 'auto resolved')
        COMMENT = 'Whether the final decision on the job was automated',
    jobs.job_was_escalated AS jobs.was_escalated
        WITH SYNONYMS = ('escalated', 'was escalated')
        COMMENT = 'Whether the job was escalated at any point',
    jobs.job_was_moved_between_queues AS jobs.was_moved_between_queues
        WITH SYNONYMS = ('moved queue', 'changed queue', 'requeued')
        COMMENT = 'Whether the job changed queue at any point',
    jobs.job_created_date AS jobs.created_date
        WITH SYNONYMS = ('job created date', 'date created', 'when the job was created'),
    jobs.job_closed_date AS jobs.closed_date
        WITH SYNONYMS = ('closed date', 'date closed', 'closure date', 'day closed'),
    jobs.job_closed_month AS jobs.closed_month
        WITH SYNONYMS = ('closed month', 'month closed'),

    -- ---- Decision ------------------------------------------------------------------
    decisions.decision_source AS decisions.decision_source_type
        WITH SYNONYMS = ('decision source', 'how it was decided', 'manual or automated', 'decision origin')
        COMMENT = 'manual means a human decided. Every other value is machine-driven',
    decisions.decision_staffing_model AS decisions.staffing_model
        WITH SYNONYMS = ('staffing', 'staffing model', 'vendor', 'BPO', 'outsourced or in-house', 'supplier', 'team')
        COMMENT = 'Who handled the decision: the vendor name, In-house, or Automated. Prefer this over the reviewer staffing model, because it accounts for automated decisions instead of leaving them unlabelled',
    decisions.decision_is_automated AS decisions.is_automated
        WITH SYNONYMS = ('automated decision', 'machine decision', 'auto decided')
        COMMENT = 'Whether the decision was taken without a human',
    decisions.decision_is_cleared AS decisions.is_cleared_outcome
        WITH SYNONYMS = ('cleared', 'no violation found', 'reviewed and cleared')
        COMMENT = 'Policies were applied but all were non-violating — reviewed and found fine',
    decisions.decision_date AS decisions.decided_date
        WITH SYNONYMS = ('decision date', 'date decided', 'day decided'),
    decisions.decision_month AS decisions.decided_month
        WITH SYNONYMS = ('decision month', 'month decided'),
    decisions.decision_hour_of_day AS decisions.decided_hour_of_day
        WITH SYNONYMS = ('hour of day', 'time of day decided', 'shift hour'),

    -- ---- Job action ----------------------------------------------------------------
    job_actions.action_type AS job_actions.action
        WITH SYNONYMS = ('action', 'action type', 'what happened', 'movement type')
        COMMENT = 'The lifecycle action — created, changed_queue, escalated, cancelled and others',
    job_actions.action_source AS job_actions.action_source
        WITH SYNONYMS = ('action source', 'who or what acted')
        COMMENT = 'One of manual, workflow, auto, api, agent',
    job_actions.action_actor_type AS job_actions.actor_type
        WITH SYNONYMS = ('actor', 'actor type', 'human or workflow')
        COMMENT = 'user, workflow, or none. Sources auto, api and agent carry neither',
    job_actions.action_date AS job_actions.actioned_date
        WITH SYNONYMS = ('action date', 'date actioned', 'day actioned'),
    job_actions.action_workflow_name AS job_actions.actor_workflow_name
        WITH SYNONYMS = ('workflow', 'workflow name', 'automation name')
        COMMENT = 'Workflow that took the action, when a workflow did'

)

METRICS (

    -- ---- Job volume and cycle time -------------------------------------------------
    jobs.total_jobs AS COUNT(jobs.job_key)
        WITH SYNONYMS = ('jobs', 'number of jobs', 'job count', 'total cases')
        COMMENT = 'Jobs seen on either event, open or closed',
    jobs.closed_jobs AS SUM(IFF(jobs.is_closed, 1, 0))
        WITH SYNONYMS = ('closed jobs', 'jobs closed', 'resolved jobs', 'completed jobs')
        COMMENT = 'Jobs with a closure event. A floor, not a total — Cinder sends no closure event for a job that closes with zero decisions',
    jobs.open_jobs AS SUM(IFF(jobs.is_closed, 0, 1))
        WITH SYNONYMS = ('open jobs', 'backlog', 'unresolved jobs', 'jobs still open')
        COMMENT = 'Jobs with no closure event seen',
    jobs.median_time_to_close_hours AS MEDIAN(jobs.job_time_to_close_hours)
        WITH SYNONYMS = ('median time to close', 'typical time to close', 'median resolution time')
        COMMENT = 'Median hours from job creation to closure. Median rather than mean, because cycle time is heavily skewed by a few very old jobs',
    jobs.avg_time_to_close_hours AS AVG(jobs.job_time_to_close_hours)
        WITH SYNONYMS = ('average time to close', 'mean time to close'),
    jobs.median_queue_wait_hours AS MEDIAN(jobs.job_wait_time_hours)
        WITH SYNONYMS = ('queue wait', 'waiting time', 'time before first action', 'time in queue')
        COMMENT = 'Median hours from job creation to the first action — waiting time, as distinct from review time',
    jobs.median_post_decision_lag_hours AS MEDIAN(jobs.job_post_decision_lag_hours)
        WITH SYNONYMS = ('lag after decision', 'time from decision to close')
        COMMENT = 'Median hours between the final decision and the job closing. A large value means jobs sit open after the call is made',

    -- ---- Job lifecycle churn -------------------------------------------------------
    jobs.avg_queue_changes_per_job AS AVG(jobs.job_queue_changes)
        WITH SYNONYMS = ('queue changes per job', 'average requeues', 'how many times jobs move queue')
        COMMENT = 'Average number of queue changes a job undergoes',
    jobs.total_queue_changes AS SUM(jobs.job_queue_changes)
        WITH SYNONYMS = ('queue changes', 'total requeues'),
    jobs.escalated_jobs AS SUM(IFF(jobs.was_escalated, 1, 0))
        WITH SYNONYMS = ('escalated jobs', 'jobs escalated'),
    jobs.jobs_cancelled_by_workflow AS SUM(IFF(jobs.was_cancelled_by_workflow, 1, 0))
        WITH SYNONYMS = ('cancelled by workflow', 'jobs cancelled by automation', 'auto cancelled jobs')
        COMMENT = 'Jobs cancelled by an automated workflow rather than by a person',
    jobs.jobs_closed_by_automation AS SUM(IFF(jobs.closed_by_automated_decision, 1, 0))
        WITH SYNONYMS = ('jobs closed automatically', 'automated closures'),

    -- ---- Decision volume and handle time -------------------------------------------
    decisions.total_decisions AS COUNT(decisions.decision_sk)
        WITH SYNONYMS = ('decisions', 'number of decisions', 'decision count', 'verdicts')
        COMMENT = 'Decisions recorded on closed jobs',
    decisions.median_handle_time_hours AS MEDIAN(decisions.decision_handle_time_hours)
        WITH SYNONYMS = ('handle time', 'median handle time', 'typical handle time', 'AHT')
        COMMENT = 'Median hours from job creation to decision. The measure meant by handle time when comparing queues and moderators',
    decisions.avg_handle_time_hours AS AVG(decisions.decision_handle_time_hours)
        WITH SYNONYMS = ('average handle time', 'mean handle time', 'average AHT'),
    -- The tail, which is where the harm and the SLA breaches live. A median says what a
    -- typical case looked like; it says nothing about the slowest tenth, and moderation
    -- commitments are almost always written as a percentile rather than an average. A queue
    -- with a comfortable median and a p90 of three days has a real backlog problem that the
    -- median actively conceals.
    decisions.p90_handle_time_hours AS PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY decisions.decision_handle_time_hours)
        WITH SYNONYMS = ('p90 handle time', '90th percentile handle time', 'slowest decisions', 'tail handle time', 'worst case handle time', 'SLA handle time')
        COMMENT = 'Hours from job creation to decision at the 90th percentile. Use with the median, not instead of it — a gap between the two is the backlog',
    decisions.automated_decisions AS SUM(IFF(decisions.is_automated, 1, 0))
        WITH SYNONYMS = ('automated decisions', 'machine decisions'),
    decisions.human_decisions AS SUM(IFF(decisions.is_human_decision, 1, 0))
        WITH SYNONYMS = ('human decisions', 'manual decisions', 'decisions by people'),
    decisions.violating_decisions AS SUM(IFF(decisions.is_violating_outcome, 1, 0))
        WITH SYNONYMS = ('violations', 'violating decisions', 'enforcement decisions')
        COMMENT = 'Decisions applying at least one violating policy',
    decisions.cleared_decisions AS SUM(IFF(decisions.is_cleared_outcome, 1, 0))
        WITH SYNONYMS = ('cleared', 'no violation', 'decisions with no violation')
        COMMENT = 'Decisions where every applied policy was non-violating',
    decisions.illegal_decisions AS SUM(IFF(decisions.is_illegal_outcome, 1, 0))
        WITH SYNONYMS = ('illegal content decisions', 'legally reportable decisions'),
    decisions.total_enforcement_actions AS SUM(decisions.decision_enforcement_actions)
        WITH SYNONYMS = ('enforcement actions', 'actions applied', 'enforcement volume'),
    decisions.active_moderators AS COUNT(DISTINCT decisions.reviewer_email)
        WITH SYNONYMS = ('moderators deciding', 'distinct moderators', 'moderators who decided')
        COMMENT = 'Distinct moderators who recorded a decision',

    -- ---- Moderator activity from job actions ---------------------------------------
    job_actions.total_job_actions AS COUNT(job_actions.job_action_event_sk)
        WITH SYNONYMS = ('job actions', 'actions', 'activity', 'moderator activity', 'throughput'),
    job_actions.active_moderators_by_activity AS COUNT(DISTINCT job_actions.actor_user_email)
        WITH SYNONYMS = ('active moderators', 'moderators active', 'daily active moderators', 'headcount active')
        COMMENT = 'Distinct moderators who took any job action. Use this for active-moderator counts — it captures moderators who moved work without deciding it',
    job_actions.median_job_age_at_action_hours AS MEDIAN(job_actions.action_job_age_hours)
        WITH SYNONYMS = ('job age when actioned', 'median age of actioned jobs', 'age at action')
        COMMENT = 'Median age of a job at the moment it was actioned',

    -- ---- Policy distribution -------------------------------------------------------
    decision_policies.policy_applications AS COUNT(decision_policies.decision_policy_sk)
        WITH SYNONYMS = ('policy applications', 'times a policy was applied', 'policy volume')
        COMMENT = 'Raw policy volume. Sums to more than the decision count, because one decision can apply several policies',
    decision_policies.allocated_decisions AS SUM(decision_policies.policy_allocated_decisions)
        WITH SYNONYMS = ('decisions by policy', 'allocated decisions', 'share of decisions')
        COMMENT = 'Decisions split fractionally across their policies, so a distribution adds up to the true decision total',

    -- ---- Derived rates -------------------------------------------------------------
    -- Derived metrics reference other metrics without a table prefix.
    automation_rate AS decisions.automated_decisions / NULLIF(decisions.total_decisions, 0)
        WITH SYNONYMS = ('automation rate', 'share automated', 'percent automated', 'automation share')
        COMMENT = 'Share of decisions taken without a human',
    automated_closure_rate AS jobs.jobs_closed_by_automation / NULLIF(jobs.closed_jobs, 0)
        WITH SYNONYMS = ('share of jobs closed automatically', 'automated close rate')
        COMMENT = 'Share of closed jobs whose final decision was automated',
    clearance_rate AS decisions.cleared_decisions / NULLIF(decisions.total_decisions, 0)
        WITH SYNONYMS = ('clearance rate', 'no violation rate', 'share cleared')
        COMMENT = 'Share of decisions that found no violation',
    violation_rate AS decisions.violating_decisions / NULLIF(decisions.total_decisions, 0)
        WITH SYNONYMS = ('violation rate', 'share violating', 'enforcement rate'),
    escalation_rate AS jobs.escalated_jobs / NULLIF(jobs.total_jobs, 0)
        WITH SYNONYMS = ('escalation rate', 'share escalated'),
    decisions_per_moderator AS decisions.total_decisions / NULLIF(decisions.active_moderators, 0)
        WITH SYNONYMS = ('decisions per moderator', 'productivity', 'output per moderator')

)

COMMENT = 'Trust and Safety moderation analytics over Cinder webhook events. Four grains: jobs, decisions, policy applications and job actions. Closure and decision counts are floors rather than totals, because Cinder sends no job.closed event for a job that closes with zero decisions.'

AI_SQL_GENERATION 'Prefer policy_area over policy_name when asked about policy distribution, because leaf-level policies fragment into unreadably thin slices. Use median rather than average for any duration unless average is explicitly requested, because handle time and time to close are heavily right-skewed. When asked about active moderators, prefer active_moderators_by_activity from job_actions over active_moderators from decisions, because the former also counts moderators who moved work without deciding it. Never treat a non-violating policy as a violation: cleared_decisions and violating_decisions are distinct and must not be added together. When counting decisions by policy, use allocated_decisions if the result must sum to the decision total, and policy_applications if raw policy volume is wanted.'

AI_VERIFIED_QUERIES (

    -- The questions the moderation team actually asked, encoded so Cortex Analyst is
    -- grounded on their phrasing rather than guessing at it. Each one is a worked example of
    -- the correct grain and the correct aggregation for that question.

    closed_jobs_per_day AS (
        QUESTION 'How many jobs are closed each day?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS jobs.job_closed_date
                METRICS jobs.closed_jobs
             ) ORDER BY job_closed_date'
    ),

    top_moderators_by_activity AS (
        QUESTION 'Who are the top moderators by activity?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS reviewers.moderator_email
                METRICS job_actions.total_job_actions
             ) ORDER BY total_job_actions DESC LIMIT 20'
    ),

    active_moderators_per_day AS (
        QUESTION 'How many moderators were active each day?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS job_actions.action_date
                METRICS job_actions.active_moderators_by_activity
             ) ORDER BY action_date'
    ),

    policy_distribution AS (
        QUESTION 'What is the distribution of moderation policies?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS policies.policy_area
                METRICS decision_policies.policy_applications
             ) ORDER BY policy_applications DESC'
    ),

    escalations_and_queue_changes_per_day AS (
        QUESTION 'How many jobs are escalated or change queue per day?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS job_actions.action_date, job_actions.action_type
                METRICS job_actions.total_job_actions
             ) WHERE action_type IN (''escalated'', ''changed_queue'') ORDER BY action_date'
    ),

    jobs_cancelled_by_workflow AS (
        QUESTION 'How many jobs were cancelled by a workflow?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                METRICS jobs.jobs_cancelled_by_workflow
             )'
    ),

    median_age_of_actioned_jobs AS (
        QUESTION 'What is the median age of a job that has been actioned?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS job_actions.action_type
                METRICS job_actions.median_job_age_at_action_hours
             ) ORDER BY median_job_age_at_action_hours DESC'
    ),

    handle_time_by_queue AS (
        QUESTION 'What is the average handle time per decision by queue?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS queues.queue_name
                METRICS decisions.median_handle_time_hours, decisions.total_decisions
             ) ORDER BY median_handle_time_hours DESC'
    ),

    handle_time_tail_by_queue AS (
        QUESTION 'Which queues have the worst tail latency — where is the p90 handle time far above the median?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS queues.queue_name
                METRICS decisions.median_handle_time_hours, decisions.p90_handle_time_hours, decisions.total_decisions
             ) ORDER BY p90_handle_time_hours DESC'
    ),

    handle_time_by_moderator AS (
        QUESTION 'What is the handle time per decision by moderator?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS reviewers.moderator_name
                METRICS decisions.median_handle_time_hours, decisions.total_decisions
             ) ORDER BY median_handle_time_hours DESC'
    ),

    handle_time_by_entity_type AS (
        QUESTION 'What is the handle time per decision by entity type?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS entities.entity_type
                METRICS decisions.median_handle_time_hours, decisions.total_decisions
             ) ORDER BY median_handle_time_hours DESC'
    ),

    median_time_to_close_by_queue AS (
        QUESTION 'What is the median time to close a job by queue?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS queues.queue_name
                METRICS jobs.median_time_to_close_hours, jobs.closed_jobs
             ) ORDER BY median_time_to_close_hours DESC'
    ),

    automated_closure_share AS (
        QUESTION 'What share of jobs are closed through an automated decision?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                METRICS automated_closure_rate, jobs.closed_jobs, jobs.jobs_closed_by_automation
             )'
    ),

    queue_changes_before_closure AS (
        QUESTION 'How many queue changes does a job undergo before it is closed?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS jobs.job_is_closed
                METRICS jobs.avg_queue_changes_per_job, jobs.total_queue_changes, jobs.total_jobs
             )'
    ),

    moderator_best_queue_by_handle_time AS (
        QUESTION 'Do some moderators have a best queue in terms of handle time?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS reviewers.moderator_name, queues.queue_name
                METRICS decisions.median_handle_time_hours, decisions.total_decisions
             ) ORDER BY moderator_name, median_handle_time_hours'
    ),

    handle_time_by_staffing_model AS (
        QUESTION 'How does handle time compare between in-house, outsourced and automated?'
        SQL 'SELECT * FROM SEMANTIC_VIEW(
                {{ this }}
                DIMENSIONS decisions.decision_staffing_model
                METRICS decisions.median_handle_time_hours, decisions.total_decisions
             ) ORDER BY median_handle_time_hours DESC'
    )

)
