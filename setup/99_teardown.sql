-- =====================================================================================
-- 99 — Teardown
-- =====================================================================================
-- Drops everything this project created. Destructive and not reversible beyond Snowflake's
-- own Time Travel retention.
--
-- ORDER MATTERS, and not for the usual dependency reasons. Masking policies cannot be dropped
-- while attached to a column, and tags cannot be dropped while a policy is attached to them.
-- So attachments are removed first, then policies, then tags, then the databases. Running this
-- out of order leaves orphaned policies that block the next clean setup.
--
-- Run as ACCOUNTADMIN. Prefer `make teardown`, which asks for confirmation first.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;

-- -------------------------------------------------------------------------------------
-- Stop the schedules first, so nothing recreates objects mid-teardown
-- -------------------------------------------------------------------------------------
ALTER TASK IF EXISTS CINDER_ANALYTICS.DBT.RUN_CINDER_WEBHOOKS SUSPEND;
ALTER ALERT IF EXISTS CINDER_ANALYTICS.ADMIN.ALERT_INGESTION_STALLED SUSPEND;
ALTER ALERT IF EXISTS CINDER_ANALYTICS.ADMIN.ALERT_DBT_BUILD_FAILED SUSPEND;

DROP TASK IF EXISTS CINDER_ANALYTICS.DBT.RUN_CINDER_WEBHOOKS;
DROP ALERT IF EXISTS CINDER_ANALYTICS.ADMIN.ALERT_INGESTION_STALLED;
DROP ALERT IF EXISTS CINDER_ANALYTICS.ADMIN.ALERT_DBT_BUILD_FAILED;

-- -------------------------------------------------------------------------------------
-- Detach masking policies from the landing tables
-- -------------------------------------------------------------------------------------
-- Dropping the databases would take these with them, but the policies live in
-- CINDER_ANALYTICS while one of the tables lives in CINDER_RAW — so whichever database is
-- dropped second leaves a dangling reference. Detaching explicitly avoids the ordering trap.
ALTER TABLE IF EXISTS CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED
    MODIFY COLUMN PAYLOAD UNSET MASKING POLICY;
ALTER TABLE IF EXISTS CINDER_RAW.OPENFLOW_CINDER.JOB_CLOSED
    MODIFY COLUMN PAYLOAD UNSET MASKING POLICY;

-- -------------------------------------------------------------------------------------
-- Detach policies from the tag, then drop them
-- -------------------------------------------------------------------------------------
ALTER TAG IF EXISTS CINDER_ANALYTICS.ADMIN.PII_CATEGORY
    UNSET MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT;
ALTER TAG IF EXISTS CINDER_ANALYTICS.ADMIN.PII_CATEGORY
    UNSET MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_VARIANT;

-- Column tags go with the tables when the database is dropped, so they need no explicit
-- removal — but the tag itself cannot be dropped until nothing references it.
DROP TAG IF EXISTS CINDER_ANALYTICS.ADMIN.PII_CATEGORY;

DROP MASKING POLICY IF EXISTS CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT;
DROP MASKING POLICY IF EXISTS CINDER_ANALYTICS.ADMIN.MASK_PII_VARIANT;
DROP MASKING POLICY IF EXISTS CINDER_ANALYTICS.ADMIN.MASK_RAW_PAYLOAD;

-- -------------------------------------------------------------------------------------
-- Classification
-- -------------------------------------------------------------------------------------
ALTER SCHEMA IF EXISTS CINDER_ANALYTICS.MARTS UNSET CLASSIFICATION_PROFILE;
DROP SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE IF EXISTS
    CINDER_ANALYTICS.ADMIN.CINDER_CLASSIFICATION_PROFILE;

-- -------------------------------------------------------------------------------------
-- The dbt project object
-- -------------------------------------------------------------------------------------
DROP DBT PROJECT IF EXISTS CINDER_ANALYTICS.DBT.CINDER_WEBHOOKS;

-- -------------------------------------------------------------------------------------
-- Databases
-- -------------------------------------------------------------------------------------
DROP DATABASE IF EXISTS CINDER_ANALYTICS;
DROP DATABASE IF EXISTS CINDER_RAW;

-- -------------------------------------------------------------------------------------
-- Account-level objects
-- -------------------------------------------------------------------------------------
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS CINDER_DEMO_DBT_EAI;
DROP NOTIFICATION INTEGRATION IF EXISTS CINDER_DEMO_ALERTS;
DROP WAREHOUSE IF EXISTS CINDER_DEMO_WH;

DROP ROLE IF EXISTS CINDER_DBT_PROD_ROLE;
DROP ROLE IF EXISTS CINDER_DBT_CI_ROLE;
DROP ROLE IF EXISTS CINDER_PII_READER;
DROP ROLE IF EXISTS CINDER_ANALYST_NO_PII;

-- -------------------------------------------------------------------------------------
-- Verification — all of these should return nothing
-- -------------------------------------------------------------------------------------
SHOW DATABASES LIKE 'CINDER_%';
SHOW WAREHOUSES LIKE 'CINDER_%';
SHOW ROLES LIKE 'CINDER_%';
