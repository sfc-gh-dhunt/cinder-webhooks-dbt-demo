-- =====================================================================================
-- 05 — Reapply column tags to the dbt-built tables
-- =====================================================================================
-- WHY THIS FILE EXISTS SEPARATELY FROM 03_governance.sql.
--
-- Column tags do not survive a rebuild. dbt materialises a table with CREATE OR REPLACE,
-- which replaces the object — and the tags were attached to the OLD object's columns. The
-- new table arrives untagged, and because masking here is tag-driven, untagged means
-- unmasked. Nobody gets an error. The pipeline goes green and the data is exposed.
--
-- So tagging splits into two jobs with genuinely different lifecycles:
--
--   03_governance.sql  Creates the tag, the masking policies, and the roles, and protects
--                      the raw landing tables. One-time, needs an administrator, and the
--                      raw tables are not rebuilt so their protection is durable.
--
--   05 (this file)     Reapplies tags to tables dbt rebuilds. Runs after EVERY build, as
--                      part of deployment, and needs only the privileges below.
--
-- Keeping them together would force the whole governance script — role creation, policy
-- DDL, ACCOUNTADMIN — into the deploy path. A CI service user would then need
-- ACCOUNTADMIN to publish a model, which is precisely the wrong trade.
--
-- PRIVILEGES REQUIRED. Deliberately small:
--   * OWNERSHIP of the tables being altered — the deploy role built them, so it has this
--   * APPLY on the tag — granted to the deploy role in 03_governance.sql
-- No ACCOUNTADMIN. Run this as the role that builds the models.
--
-- RUN ORDER: after 03 (the tag and policies must exist) and after a SUCCESSFUL BUILD (the
-- tables must exist). Then after every build thereafter.
--
-- IDEMPOTENT. Setting a tag that is already set to the same value is a no-op, so this is
-- safe to run after every build whether anything was rebuilt or not.
--
-- IF YOU ADD A TAGGED COLUMN, ADD IT HERE. A column tagged manually in the UI will be
-- silently dropped by the next rebuild. This file is the source of truth.
-- =====================================================================================

-- No USE ROLE. The caller's role applies, so the same script serves a local `make deploy`
-- and the CI deploy workflow without editing.

-- -------------------------------------------------------------------------------------
-- Moderator identity
-- -------------------------------------------------------------------------------------
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_REVIEWER
    MODIFY COLUMN REVIEWER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_REVIEWER
    MODIFY COLUMN REVIEWER_NAME SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'NAME';

-- -------------------------------------------------------------------------------------
-- Entity identity and content
-- -------------------------------------------------------------------------------------
-- `entity_id` is hashed rather than blanked so it stays joinable and countable — an
-- unprivileged analyst can still ask "how many distinct users" without seeing who.
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_USERNAME SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'USERNAME';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_CAPTION SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'FREE_TEXT';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_ATTRIBUTES SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'IDENTIFIER';

-- -------------------------------------------------------------------------------------
-- Degenerate dimensions on the facts
-- -------------------------------------------------------------------------------------
-- Easy to forget, and they are the same personal data as in the dimension. A masking
-- policy on DIM_REVIEWER.REVIEWER_EMAIL protects nothing if the same address is sitting
-- unmasked on the fact next to it.
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_DECISIONS
    MODIFY COLUMN REVIEWER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOB_ACTIONS
    MODIFY COLUMN ACTOR_USER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOBS
    MODIFY COLUMN FINAL_REVIEWER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';

-- -------------------------------------------------------------------------------------
-- Verify, rather than assume
-- -------------------------------------------------------------------------------------
-- Tagging succeeds silently and masking is invisible until someone queries the data as an
-- unprivileged role — so a deploy that skipped this file looks identical to one that ran it.
-- This reads back what is actually attached.
--
-- SYSTEM$GET_TAG, not ACCOUNT_USAGE.TAG_REFERENCES, for two reasons. ACCOUNT_USAGE lags by
-- up to two hours, so it cannot confirm a tag applied seconds ago — it would report the
-- PREVIOUS state and call a broken deploy healthy. It also requires privileges on the
-- SNOWFLAKE database that a deploy role has no other reason to hold.
--
-- Every column below must return its category. A NULL means the tag did not apply, which
-- means that column is unmasked.
SELECT
      'DIM_REVIEWER.REVIEWER_EMAIL' AS tagged_column
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.DIM_REVIEWER.REVIEWER_EMAIL', 'COLUMN') AS pii_category
UNION ALL SELECT 'DIM_REVIEWER.REVIEWER_NAME'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.DIM_REVIEWER.REVIEWER_NAME', 'COLUMN')
UNION ALL SELECT 'DIM_ENTITY.ENTITY_EMAIL'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.DIM_ENTITY.ENTITY_EMAIL', 'COLUMN')
UNION ALL SELECT 'DIM_ENTITY.ENTITY_USERNAME'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.DIM_ENTITY.ENTITY_USERNAME', 'COLUMN')
UNION ALL SELECT 'DIM_ENTITY.ENTITY_CAPTION'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.DIM_ENTITY.ENTITY_CAPTION', 'COLUMN')
UNION ALL SELECT 'DIM_ENTITY.ENTITY_ATTRIBUTES'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.DIM_ENTITY.ENTITY_ATTRIBUTES', 'COLUMN')
UNION ALL SELECT 'FCT_DECISIONS.REVIEWER_EMAIL'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.FCT_DECISIONS.REVIEWER_EMAIL', 'COLUMN')
UNION ALL SELECT 'FCT_JOB_ACTIONS.ACTOR_USER_EMAIL'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.FCT_JOB_ACTIONS.ACTOR_USER_EMAIL', 'COLUMN')
UNION ALL SELECT 'FCT_JOBS.FINAL_REVIEWER_EMAIL'
    , SYSTEM$GET_TAG('CINDER_ANALYTICS.ADMIN.PII_CATEGORY', 'CINDER_ANALYTICS.MARTS.FCT_JOBS.FINAL_REVIEWER_EMAIL', 'COLUMN')
;
