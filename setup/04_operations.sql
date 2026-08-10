-- =====================================================================================
-- 04 — Operations: scheduling, monitoring and alerting
-- =====================================================================================
-- WHERE THE LINE IS DRAWN BETWEEN dbt TESTS AND SNOWFLAKE DATA METRIC FUNCTIONS
--
-- Both check data. They are not alternatives, and running the same assertion on both sides
-- is how you end up maintaining two versions of the same test that disagree.
--
--   dbt tests own LOGIC, at BUILD TIME.
--       Surrogate key uniqueness, referential integrity, accepted enum values, business
--       invariants. These are properties of the TRANSFORMATION, so they belong with the code
--       that creates it and they should block a bad build. They are already in the project.
--
--   Data metric functions own STATE, CONTINUOUSLY.
--       Freshness and row volume on the landing tables, null rates on the columns the
--       semantic view depends on. These must fire when NO BUILD IS RUNNING. If ingestion
--       stops at 03:00 and dbt is not scheduled until 06:00, no dbt test will ever notice —
--       there is nothing to run.
--
-- The dividing question: "would I want to know about this even if the pipeline never ran
-- again?" If yes, it is a DMF. If it is about whether the transformation is correct, it is a
-- dbt test.
--
-- ONE ASSERTION IS DELIBERATELY DUPLICATED. Freshness is declared in the dbt sources (as a
-- build gate — do not rebuild on stale data) and again as a DMF (as out-of-band alerting).
-- Same assertion, two different consumers, and neither can do the other's job. This is a
-- decision, not an oversight.
--
-- Nothing else is duplicated. There are no null or uniqueness checks on both sides.
--
-- Run as ACCOUNTADMIN — creating a notification integration and granting the data metric
-- role both require it.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE CINDER_DEMO_WH;

-- -------------------------------------------------------------------------------------
-- Step 1 — Privileges for data metric functions
-- -------------------------------------------------------------------------------------
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE CINDER_DBT_PROD_ROLE;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE CINDER_DBT_PROD_ROLE;

-- -------------------------------------------------------------------------------------
-- Step 2 — Monitor the landing zone
-- -------------------------------------------------------------------------------------
-- This is the monitoring that matters most, and the reason is worth stating: if ingestion
-- stops, everything downstream keeps returning yesterday's answer, confidently and without
-- error. Nothing breaks. The dashboards still load. That is the failure mode this catches.

-- The schedule applies to all metrics attached to the table. 30 minutes is a reasonable
-- floor for a webhook feed — frequent enough to notice a stall within a shift, infrequent
-- enough to be cheap.
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED
    SET DATA_METRIC_SCHEDULE = '30 MINUTE';
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_CLOSED
    SET DATA_METRIC_SCHEDULE = '30 MINUTE';

-- FRESHNESS, in its zero-argument form: the age in seconds of the table's last update,
-- taken from table metadata rather than from any column.
--
-- TWO REASONS IT IS THE RIGHT CHOICE HERE, one practical and one that will bite you.
--
-- The practical one: the question being asked is "is the PIPELINE alive", not "how old is the
-- newest event". Those differ. If Cinder itself went quiet, event timestamps would age while
-- the pipeline remained perfectly healthy, and a column-based check would conflate the two.
-- Table last-update time answers the question actually being asked.
--
-- The one that will bite you: the column-based FRESHNESS overloads cover DATE, TIMESTAMP_LTZ
-- and TIMESTAMP_TZ — but NOT TIMESTAMP_NTZ. IMPORT_TS is TIMESTAMP_NTZ, because that is what
-- the ingestion layer writes: naive wall-clock with no offset. Passing it to FRESHNESS fails
-- with "Function FRESHNESS$V1 does not exist or not authorized", which reads like a
-- privileges problem and is in fact a type problem.
--
-- If you do need column-based freshness, cast the column to TIMESTAMP_TZ in a view and attach
-- the metric there — do not change the landing column type. The naive timestamp is the
-- ingestion layer's contract, not a modelling choice you get to make.
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON ();
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_CLOSED
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON ();

-- ROW_COUNT gives the volume trend. A table that is fresh but flat is a subtler failure than
-- one that has stopped: it usually means a routing rule changed and one event type quietly
-- stopped arriving while the others carried on.
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_CLOSED
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

-- NOT DONE HERE, AND WORTH KNOWING WHY: a null payload check.
--
-- A landed row with a null payload means the webhook body failed to parse — the delivery
-- arrived and its content did not, and every downstream model would treat it as an event that
-- happened but had no detail. Clearly worth checking.
--
-- But the built-in data metric functions have no VARIANT overloads at all. NULL_COUNT covers
-- VARCHAR, NUMBER, FLOAT, DATE and the timestamp types; passing it a VARIANT fails with
-- "Function NULL_COUNT$V1 does not exist or not authorized" — again a type problem wearing the
-- costume of a privileges problem.
--
-- So this check stays where it already is: a `not_null` test on the PAYLOAD column in
-- models/sources/sources.yml. That is not a workaround, it is the correct side of the line —
-- a null payload is caught the moment anything tries to build on it, which is when you can
-- still do something about it.
--
-- The general rule this illustrates: DMFs cannot see inside or reason about semi-structured
-- data. Anything VARIANT-shaped belongs to dbt.

-- -------------------------------------------------------------------------------------
-- Step 3 — Monitor what the semantic view depends on
-- -------------------------------------------------------------------------------------
-- Deliberately sparse. dbt already asserts uniqueness and referential integrity on these
-- tables at build time, and repeating that here would be the duplication this file exists to
-- avoid. What dbt cannot tell you is whether a table that built successfully has since become
-- unreasonable — an empty fact table after a partially-failed run looks identical to a quiet
-- day.
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOBS
    SET DATA_METRIC_SCHEDULE = 'USING CRON 0 7 * * * UTC';
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOBS
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

-- A null handle time is legitimate on any individual row — an open job has none. A RISE in
-- the null rate is not: it means job creation timestamps have stopped arriving, and every
-- handle-time metric silently narrows to the rows that still have one.
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOBS
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (JOB_CREATED_AT);

ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_DECISIONS
    SET DATA_METRIC_SCHEDULE = 'USING CRON 0 7 * * * UTC';
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_DECISIONS
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

-- -------------------------------------------------------------------------------------
-- Step 4 — Schedule the dbt project
-- -------------------------------------------------------------------------------------
-- The deployed project object is the production run target. A task is what runs it.
--
-- `build` rather than `run`, because `build` interleaves models and their tests in dependency
-- order — a downstream model is not built on top of a parent that just failed its tests.
-- Running `run` then `test` separately would publish bad data first and complain afterwards.
CREATE OR REPLACE TASK CINDER_ANALYTICS.DBT.RUN_CINDER_WEBHOOKS
    WAREHOUSE = CINDER_DEMO_WH
    SCHEDULE = 'USING CRON 0 6 * * * UTC'
    -- Suspend after repeated failure rather than retrying indefinitely into a broken
    -- upstream. Three consecutive failures is a problem no amount of retrying will fix, and
    -- an unattended task can burn a lot of credits discovering that.
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
    COMMENT = 'Daily build of the Cinder webhooks dbt project'
AS
    EXECUTE DBT PROJECT CINDER_ANALYTICS.DBT.CINDER_WEBHOOKS
        ARGS = 'build --vars ''{"cinder_source_mode": "seed"}''';

-- Tasks are created suspended. Resume deliberately — an unattended schedule that nobody
-- decided to switch on is how a demo turns into a surprise on a credit report.
-- ALTER TASK CINDER_ANALYTICS.DBT.RUN_CINDER_WEBHOOKS RESUME;

-- -------------------------------------------------------------------------------------
-- Step 5 — Alerting
-- -------------------------------------------------------------------------------------
-- The deployed dbt project object has NO native run-failure notification. Neither do data
-- metric functions — they record results and do not tell anyone. So alerting is assembled
-- from primitives, and this is where it is assembled.
--
-- Replace the email address before running. Snowflake only sends to addresses belonging to
-- verified users in the account.
CREATE OR REPLACE NOTIFICATION INTEGRATION CINDER_DEMO_ALERTS
    TYPE = EMAIL
    ENABLED = TRUE
    COMMENT = 'Email alerts for the Cinder webhooks pipeline';

GRANT USAGE ON INTEGRATION CINDER_DEMO_ALERTS TO ROLE CINDER_DBT_PROD_ROLE;

-- ---- Alert 1: the pipeline stopped ---------------------------------------------------
-- Reads the DMF results rather than re-querying the tables. That matters: the metric has
-- already been computed on its own schedule, so this alert is a cheap read of a result set
-- rather than a second scan of the data.
CREATE OR REPLACE ALERT CINDER_ANALYTICS.ADMIN.ALERT_INGESTION_STALLED
    WAREHOUSE = CINDER_DEMO_WH
    SCHEDULE = '60 MINUTE'
    IF (EXISTS (
        SELECT 1
        FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
        WHERE METRIC_NAME = 'FRESHNESS'
          AND TABLE_DATABASE = 'CINDER_RAW'
          AND MEASUREMENT_TIME >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
          -- Six hours matches the warn threshold on the dbt source freshness declaration, so
          -- the two surfaces agree on what "stale" means. If you change one, change both.
          AND VALUE > 6 * 60 * 60
    ))
    THEN CALL SYSTEM$SEND_EMAIL(
        'CINDER_DEMO_ALERTS',
        'REPLACE_WITH_YOUR_EMAIL@example.com',
        'Cinder ingestion appears stalled',
        'A Cinder landing table has not received a row in over 6 hours. '
        || 'Check the ingestion runtime and the webhook endpoint configuration. '
        || 'Downstream models will keep returning the last good answer without error.'
    );

-- ---- Alert 2: the scheduled build failed ---------------------------------------------
-- TASK_HISTORY, not the dbt artifacts. A task that failed to start produces no dbt artifacts
-- at all, so an artifact-based check would miss the very failure that matters most.
CREATE OR REPLACE ALERT CINDER_ANALYTICS.ADMIN.ALERT_DBT_BUILD_FAILED
    WAREHOUSE = CINDER_DEMO_WH
    SCHEDULE = 'USING CRON 30 6 * * * UTC'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
            TASK_NAME => 'RUN_CINDER_WEBHOOKS',
            SCHEDULED_TIME_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP())
        ))
        WHERE STATE = 'FAILED'
    ))
    THEN CALL SYSTEM$SEND_EMAIL(
        'CINDER_DEMO_ALERTS',
        'REPLACE_WITH_YOUR_EMAIL@example.com',
        'Cinder dbt build failed',
        'The scheduled dbt build failed. Query TASK_HISTORY for the error, then read the '
        || 'run logs in the dbt project object. Note the task suspends itself after three '
        || 'consecutive failures.'
    );

-- Alerts are also created suspended.
-- ALTER ALERT CINDER_ANALYTICS.ADMIN.ALERT_INGESTION_STALLED RESUME;
-- ALTER ALERT CINDER_ANALYTICS.ADMIN.ALERT_DBT_BUILD_FAILED RESUME;

-- =====================================================================================
-- Verification
-- =====================================================================================

-- Which metrics are attached, and on what schedule.
SELECT
      REF_ENTITY_NAME     AS table_name
    , METRIC_NAME
    , REF_ARGUMENTS       AS measured_on
    , SCHEDULE
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME => 'CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED',
    REF_ENTITY_DOMAIN => 'TABLE'
));

-- Results appear here once the first scheduled run completes — expect a delay of up to the
-- schedule interval after attaching. An empty result immediately after setup is normal.
--
--   SELECT MEASUREMENT_TIME, TABLE_NAME, METRIC_NAME, VALUE
--   FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
--   WHERE TABLE_DATABASE IN ('CINDER_RAW', 'CINDER_ANALYTICS')
--   ORDER BY MEASUREMENT_TIME DESC
--   LIMIT 50;

SHOW TASKS IN SCHEMA CINDER_ANALYTICS.DBT;
SHOW ALERTS IN SCHEMA CINDER_ANALYTICS.ADMIN;
