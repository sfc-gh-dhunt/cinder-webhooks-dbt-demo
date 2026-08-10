-- =====================================================================================
-- 02 — Raw landing tables
-- =====================================================================================
-- RUN ORDER: after 01_account_setup.sql (the database, schema and warehouse must exist).
-- Creates the tables the ingestion layer writes into. In a real deployment these are
-- created once and then owned by the ingestion tool's service user.
--
-- WHY THIS SHAPE
-- --------------
-- The ingestion flow this project was modelled against listens for Cinder webhooks,
-- adds an ingestion timestamp, routes on the event type, and publishes to Snowflake with
-- Snowpipe Streaming using a row-per-record strategy and a JSON record reader.
--
-- That means each landed row is the webhook body plus the injected timestamp, and the
-- top-level JSON keys map directly onto columns:
--
--     { "event": "job.actioned", "payload": { ... }, "import_ts": "2026-08-10 09:14:22" }
--        |                          |                  |
--        EVENT                      PAYLOAD            IMPORT_TS
--
-- One table per event type, because the flow routes on event type before publishing.
--
-- IMPORT_TS IS NOT EVENT TIME. It is ingestion wall-clock, second resolution, with no
-- timezone. Event time lives at payload.timestamp and is timezone-aware. The dbt models
-- use import_ts only for ingestion lineage and incremental watermarking. This is the
-- single most common modelling mistake with this kind of landing table.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE CINDER_DEMO_WH;
USE SCHEMA CINDER_RAW.OPENFLOW_CINDER;

-- -------------------------------------------------------------------------------------
-- job.actioned — a job action was created (moved queue, escalated, skipped, cancelled…)
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS JOB_ACTIONED (
    EVENT       VARCHAR         COMMENT 'Webhook event name, always job.actioned',
    PAYLOAD     VARIANT         COMMENT 'Full webhook payload object',
    IMPORT_TS   TIMESTAMP_NTZ   COMMENT 'Ingestion wall-clock time. NOT event time — see payload.timestamp'
)
COMMENT = 'Raw job.actioned webhook events as landed by the ingestion layer';

-- -------------------------------------------------------------------------------------
-- job.closed — all review work on a job finished and the job moved to a closed state
-- -------------------------------------------------------------------------------------
-- Note: this event is not subscribed by default on a new webhook endpoint. It has to be
-- enabled in the Cinder webhook endpoint configuration.
--
-- Note also: no job.closed event is sent when a job closes with zero production
-- decisions. Closure counts derived from this event therefore understate reality. The
-- dbt project asserts this as a warning-level test rather than pretending otherwise.
CREATE TABLE IF NOT EXISTS JOB_CLOSED (
    EVENT       VARCHAR         COMMENT 'Webhook event name, always job.closed',
    PAYLOAD     VARIANT         COMMENT 'Full webhook payload object, including the decisions array',
    IMPORT_TS   TIMESTAMP_NTZ   COMMENT 'Ingestion wall-clock time. NOT event time — see payload.timestamp'
)
COMMENT = 'Raw job.closed webhook events as landed by the ingestion layer';

-- -------------------------------------------------------------------------------------
-- Verification
-- -------------------------------------------------------------------------------------
SHOW TABLES IN SCHEMA CINDER_RAW.OPENFLOW_CINDER;

SELECT 'JOB_ACTIONED' AS table_name, COUNT(*) AS row_count FROM JOB_ACTIONED
UNION ALL SELECT 'JOB_CLOSED', COUNT(*) FROM JOB_CLOSED;
