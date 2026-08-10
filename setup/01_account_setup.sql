-- =====================================================================================
-- 01 — Account setup
-- =====================================================================================
-- Creates every Snowflake object this demo needs, apart from the dbt project object
-- itself (that is created by `snow dbt deploy`).
--
-- Idempotent: safe to re-run. Uses CREATE ... IF NOT EXISTS throughout.
--
-- Run as a role that can create databases, warehouses and integrations (ACCOUNTADMIN
-- or equivalent). Creating the External Access Integration and the notification
-- integration in 04 requires ACCOUNTADMIN.
--
-- Object names are deliberately generic. If you need different ones, change them here
-- and pass matching dbt vars — see README "Renaming objects".
-- =====================================================================================

USE ROLE ACCOUNTADMIN;

-- -------------------------------------------------------------------------------------
-- Warehouse
-- -------------------------------------------------------------------------------------
-- XS is ample. The seeds are tiny and the marts are small; the point of this project is
-- the modelling, not the compute. AUTO_SUSPEND is aggressive so an idle demo costs
-- nothing.
CREATE WAREHOUSE IF NOT EXISTS CINDER_DEMO_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for the Cinder webhooks dbt demo';

-- -------------------------------------------------------------------------------------
-- Databases
-- -------------------------------------------------------------------------------------
-- Two databases, mirroring the separation you would have in a real deployment: the
-- landing zone that the ingestion tool writes to, and the modelling database that dbt
-- owns. Keeping them apart means the dbt role never needs write access to raw.
CREATE DATABASE IF NOT EXISTS CINDER_RAW
    COMMENT = 'Landing zone for Cinder webhook events (written by the ingestion layer)';

CREATE DATABASE IF NOT EXISTS CINDER_ANALYTICS
    COMMENT = 'Modelled Cinder Trust & Safety analytics, owned by dbt';

-- -------------------------------------------------------------------------------------
-- Schemas
-- -------------------------------------------------------------------------------------
-- Landing schema. Named after the ingestion tool + source system, which is the
-- convention most ingestion tools default to.
CREATE SCHEMA IF NOT EXISTS CINDER_RAW.OPENFLOW_CINDER
    COMMENT = 'Raw Cinder webhook events, one table per event type';

-- Modelling schemas. One per DAG layer, so lineage is legible from object names alone.
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.ADMIN
    COMMENT = 'Network rules, tags, masking policies and other account-adjacent objects';
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.DBT
    COMMENT = 'Home of the deployed DBT PROJECT object and its scheduling task';
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.SEEDS
    COMMENT = 'Synthetic webhook payloads, loaded by dbt seed';
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.STAGING
    COMMENT = 'One view per event type: payload flattened, deduplicated, typed';
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.MARTS
    COMMENT = 'Dimensional model: conformed dimensions and event-grain facts';
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.SEMANTIC
    COMMENT = 'Semantic view over the marts, for Cortex Analyst';

-- -------------------------------------------------------------------------------------
-- External Access Integration
-- -------------------------------------------------------------------------------------
-- Snowflake runs `dbt deps` inside the account when you deploy the project. To resolve
-- packages from the dbt package hub it needs egress, which means a network rule plus an
-- External Access Integration attached at deploy time.
--
-- This project depends on Snowflake-Labs/dbt_semantic_view (for the semantic view
-- materialization) and dbt-labs/dbt_utils. Without this integration, `snow dbt deploy`
-- fails at dependency resolution.
CREATE OR REPLACE NETWORK RULE CINDER_ANALYTICS.ADMIN.DBT_PACKAGE_HUB_RULE
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com')
    COMMENT = 'Egress required by dbt deps to resolve packages during deploy';

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS CINDER_DEMO_DBT_EAI
    ALLOWED_NETWORK_RULES = (CINDER_ANALYTICS.ADMIN.DBT_PACKAGE_HUB_RULE)
    ENABLED = TRUE
    COMMENT = 'Lets dbt resolve packages from the package hub at deploy time';

-- -------------------------------------------------------------------------------------
-- Roles
-- -------------------------------------------------------------------------------------
-- Two roles, because a deployed dbt project object has to be owned by the role that
-- runs it in production, and you do not want your CI pipeline and your production
-- schedule sharing an identity.
--
--   CINDER_DBT_PROD_ROLE  owns the project object and the schedule. Used by the
--                         production service user.
--   CINDER_DBT_CI_ROLE    builds into its own schemas on pull requests. Never touches
--                         the production project object.
--
-- If you are just running the demo by hand as ACCOUNTADMIN you can skip these, but
-- they are here because the role model is the first thing that bites when a team moves
-- this pattern into production.
CREATE ROLE IF NOT EXISTS CINDER_DBT_PROD_ROLE
    COMMENT = 'Owns and runs the deployed dbt project object in production';
CREATE ROLE IF NOT EXISTS CINDER_DBT_CI_ROLE
    COMMENT = 'Builds the dbt project into throwaway schemas during CI';

-- Roll the custom roles up to SYSADMIN.
--
-- NOT optional housekeeping. Objects created by a custom role are owned by that role, and a
-- role's privileges are inherited only by roles it has been GRANTED TO. Without this, an
-- administrator using ACCOUNTADMIN or SYSADMIN cannot even SELECT from the tables and semantic
-- view this project creates — the error reads as a privileges bug in Snowflake and is in fact
-- a missing grant here.
--
-- Rolling custom roles up to SYSADMIN is the standard Snowflake pattern for exactly this
-- reason, and it is the kind of thing that is obvious once you have hit it and mystifying
-- before.
GRANT ROLE CINDER_DBT_PROD_ROLE TO ROLE SYSADMIN;
GRANT ROLE CINDER_DBT_CI_ROLE TO ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE CINDER_DEMO_WH TO ROLE CINDER_DBT_PROD_ROLE;
GRANT USAGE ON WAREHOUSE CINDER_DEMO_WH TO ROLE CINDER_DBT_CI_ROLE;

-- Read-only on the landing zone. dbt reads raw; it never writes there.
GRANT USAGE ON DATABASE CINDER_RAW TO ROLE CINDER_DBT_PROD_ROLE;
GRANT USAGE ON DATABASE CINDER_RAW TO ROLE CINDER_DBT_CI_ROLE;
GRANT USAGE ON SCHEMA CINDER_RAW.OPENFLOW_CINDER TO ROLE CINDER_DBT_PROD_ROLE;
GRANT USAGE ON SCHEMA CINDER_RAW.OPENFLOW_CINDER TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA CINDER_RAW.OPENFLOW_CINDER TO ROLE CINDER_DBT_PROD_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA CINDER_RAW.OPENFLOW_CINDER TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CINDER_RAW.OPENFLOW_CINDER TO ROLE CINDER_DBT_PROD_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CINDER_RAW.OPENFLOW_CINDER TO ROLE CINDER_DBT_CI_ROLE;

-- Full control of the modelling database.
GRANT USAGE ON DATABASE CINDER_ANALYTICS TO ROLE CINDER_DBT_PROD_ROLE;
GRANT USAGE ON DATABASE CINDER_ANALYTICS TO ROLE CINDER_DBT_CI_ROLE;
GRANT ALL ON SCHEMA CINDER_ANALYTICS.DBT TO ROLE CINDER_DBT_PROD_ROLE;
GRANT ALL ON SCHEMA CINDER_ANALYTICS.SEEDS TO ROLE CINDER_DBT_PROD_ROLE;
GRANT ALL ON SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_PROD_ROLE;
GRANT ALL ON SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_DBT_PROD_ROLE;
GRANT ALL ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_PROD_ROLE;

-- CI needs to create its own schemas and drop them again.
GRANT CREATE SCHEMA ON DATABASE CINDER_ANALYTICS TO ROLE CINDER_DBT_CI_ROLE;

-- The EAI must be granted to whichever role deploys the project.
GRANT USAGE ON INTEGRATION CINDER_DEMO_DBT_EAI TO ROLE CINDER_DBT_PROD_ROLE;
GRANT USAGE ON INTEGRATION CINDER_DEMO_DBT_EAI TO ROLE CINDER_DBT_CI_ROLE;

-- -------------------------------------------------------------------------------------
-- Verification
-- -------------------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE CINDER_ANALYTICS;
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'CINDER_DEMO_DBT_EAI';
