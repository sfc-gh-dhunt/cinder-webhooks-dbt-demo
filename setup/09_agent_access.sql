-- =============================================================================
-- 09 — Cortex Agent and evaluation access
-- =============================================================================
-- Supports models/agents/ (the Cortex Agent, its evaluation, and the two gates in
-- tests/) and the agent-gate job in .github/workflows/ci.yml.
-- Run once by an administrator.
--
-- RUN ORDER: after 04_ci_access.sql (both roles must exist).
--
-- WHY THIS IS A SEPARATE FILE rather than lines added to 01 and 04. Everything
-- here grants the ability to spend Cortex credits, and an evaluation spends them
-- per question per metric on every run. That is a different category of privilege
-- from "can create a table", and it should be possible to read what was granted
-- for it, and to revoke it, without unpicking the rest of the setup.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- Step 1 — Let both roles create and manage the agent
-- -----------------------------------------------------------------------------
-- The production role already holds CREATE AGENT from 01_account_setup.sql. It is
-- repeated here idempotently so this file is a complete statement of what the
-- agent work needs, rather than a patch that only makes sense read alongside 01.
GRANT CREATE AGENT ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_PROD_ROLE;

-- THE CI ROLE IS THE INTERESTING CASE, and the reason is worth stating because it
-- looks like a missing grant when you audit it.
--
-- CI builds into its own per-pull-request schemas (see the cinder_schema_prefix
-- var and macros/generate_schema_name.sql). It CREATES those schemas, so it owns
-- them, and an owner can create objects inside them — including agents — without
-- a schema-level CREATE AGENT grant. So the agent itself needs nothing here.
--
-- What it does need is the evaluation privileges in step 2, which are account- and
-- database-level and therefore cannot be inherited from schema ownership.

-- -----------------------------------------------------------------------------
-- Step 2 — Let both roles run an evaluation
-- -----------------------------------------------------------------------------
-- These are the documented requirements for EXECUTE_AI_EVALUATION. Each one fails
-- differently and none of the failures name the missing privilege clearly, so they
-- are listed individually with what breaks without them.

-- Calls the LLM judges. Without it the run starts and then produces no metrics,
-- which reads as "the agent scored nothing" rather than "the role cannot judge".
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CINDER_DBT_PROD_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CINDER_DBT_CI_ROLE;

-- Metrics are computed with AI_COMPLETE. USE AI FUNCTIONS is granted to PUBLIC by
-- default on most accounts, so these two statements are usually redundant — but if
-- your account has revoked it from PUBLIC they are the difference between a run and
-- a silent absence of scores.
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE CINDER_DBT_PROD_ROLE;
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE CINDER_DBT_CI_ROLE;

-- An evaluation run is orchestrated by tasks under the covers. This is an ACCOUNT
-- privilege — it cannot come from owning the schema, which is why a CI role that can
-- happily create the agent still cannot evaluate it.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE CINDER_DBT_PROD_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE CINDER_DBT_CI_ROLE;

-- The evaluation creates a DATASET from the questions table on its first run, and a
-- FILE FORMAT and TASK in whichever schema it runs from.
--
-- For the production role these are on SEMANTIC, where the agent lives. The CI role
-- needs nothing equivalent because its schemas are its own.
GRANT CREATE DATASET     ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_PROD_ROLE;
GRANT CREATE FILE FORMAT ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_PROD_ROLE;
GRANT CREATE TASK        ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_PROD_ROLE;
GRANT CREATE STAGE       ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_PROD_ROLE;

-- -----------------------------------------------------------------------------
-- Step 3 — Let the CI role read the production agent
-- -----------------------------------------------------------------------------
-- ONLY NEEDED IF you point the pull-request gate at the production agent instead of
-- the one the pull request just built. The workflow does NOT do that, deliberately:
-- a gate should grade the change, and evaluating production from a pull request both
-- tells you nothing about the change and spends credits on the wrong thing.
--
-- Left here, commented, because it is the first thing somebody will reach for when
-- they want a baseline comparison — and because MONITOR is easy to miss. USAGE alone
-- is not enough to evaluate an agent; the documented requirement is USAGE-or-
-- OWNERSHIP *and* MONITOR-or-OWNERSHIP.
--
-- GRANT USAGE   ON AGENT CINDER_ANALYTICS.SEMANTIC.AGENT_CINDER_MODERATION TO ROLE CINDER_DBT_CI_ROLE;
-- GRANT MONITOR ON AGENT CINDER_ANALYTICS.SEMANTIC.AGENT_CINDER_MODERATION TO ROLE CINDER_DBT_CI_ROLE;

-- -----------------------------------------------------------------------------
-- Step 4 — Who can talk to the agent
-- -----------------------------------------------------------------------------
-- Analysts asking the agent questions need USAGE on it and access to everything it
-- reads. The agent runs its Cortex Analyst tool against the semantic view, and a
-- caller who cannot read the underlying marts gets an agent that plans a query and
-- then cannot run it.
--
-- Masking policies and row access policies still apply — an agent is not a way
-- around them, which is the point of granting data access to the caller rather than
-- to the agent.
--
-- Adjust the role name for your account. CINDER_PII_READER exists from
-- 03_governance.sql and is used here only because it is the role this demo already
-- defines for people who look at moderation data.
GRANT USAGE ON AGENT CINDER_ANALYTICS.SEMANTIC.AGENT_CINDER_MODERATION
    TO ROLE CINDER_PII_READER;

-- -----------------------------------------------------------------------------
-- Verify
-- -----------------------------------------------------------------------------
-- The agent grant in step 4 fails if the agent has not been built yet. That is the
-- expected order: `make deploy-run` (or a local `dbt build`) first, then this file.
SHOW AGENTS IN SCHEMA CINDER_ANALYTICS.SEMANTIC;
SHOW GRANTS TO ROLE CINDER_DBT_CI_ROLE;
SHOW GRANTS TO ROLE CINDER_DBT_PROD_ROLE;
