-- =====================================================================================
-- 08 — Performance gate: read access for CI, and a fixture with enough data to matter
-- =====================================================================================
-- Supports the CoCo performance gate in .github/workflows/ci.yml, which predicts whether
-- changed dbt SQL will be slow against PRODUCTION data volumes without building anything.
-- Run once by an administrator.
--
-- RUN ORDER: after 04_ci_access.sql (the CI role must exist).
--
-- THE GATE'S PREMISE, because it determines every grant below. A dbt build in CI is the
-- normal way to catch a model that will time out, and for a large enough project it stops
-- being affordable — so the build gets skipped and the timeout is discovered in production
-- instead. The gate replaces the build with COMPILATION: `EXPLAIN` returns the query plan,
-- including how many micro-partitions each scan would touch, without executing the query
-- and without a running warehouse. It costs cloud services credits and nothing else.
--
-- The consequence is that the gate needs to READ PRODUCTION METADATA, and that is a real
-- expansion of what CI can see. Step 1 is deliberately narrow about it.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;

-- -------------------------------------------------------------------------------------
-- Step 1 — Let the CI role see production, read-only
-- -------------------------------------------------------------------------------------
-- WHY THIS IS NEEDED. `EXPLAIN` requires the same privileges as running the statement. The
-- plan for a model that reads MARTS therefore needs SELECT on MARTS — even though no row is
-- ever returned. Same for the volume figures in INFORMATION_SCHEMA and the historical
-- runtimes in ACCOUNT_USAGE.
--
-- BE CLEAR ABOUT THE TRADE. Until now the CI role could read the raw landing zone and build
-- its own throwaway schemas, and that was all. After this it can read production analytics.
-- A workflow file is just a file a contributor can edit in a pull request, so "CI can read
-- production" means "a pull request can read production".
--
-- WHAT MAKES THAT ACCEPTABLE, and it is the tool allowlist rather than the grant: the gate
-- runs Cortex Code with `--allowed "Read,Grep,Glob"` and no Bash, no Write and no Edit, so
-- the agent cannot open a connection of its own or exfiltrate what it reads. The grants
-- below are SELECT and metadata only — never write. If you are adopting this on an account
-- where production analytics is genuinely sensitive, the right move is a separate reader
-- role on a masked view of production, not a wider grant here.
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.SEEDS   TO ROLE CINDER_DBT_CI_ROLE;
-- PERF_FIXTURE holds the incremental model's target. Easy to forget, and the failure is
-- confusing: the gate reports the source scan happily and then cannot plan the merge, because
-- EXPLAIN on a MERGE needs SELECT on the object being merged INTO.
CREATE SCHEMA IF NOT EXISTS CINDER_ANALYTICS.PERF_FIXTURE
    COMMENT = 'Target of the incremental fixture model. Exists for the CI performance gate.';
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.PERF_FIXTURE TO ROLE CINDER_DBT_CI_ROLE;

-- Tables AND views AND dynamic tables. The marts in this project are dynamic tables, and a
-- dynamic table is not covered by `ON ALL TABLES` — miss this and every EXPLAIN of a mart
-- fails with "does not exist or not authorized", which reads like a typo rather than a
-- missing grant.
GRANT SELECT ON ALL TABLES         IN SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL VIEWS          IN SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL TABLES         IN SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL VIEWS          IN SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL TABLES         IN SCHEMA CINDER_ANALYTICS.SEEDS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL TABLES         IN SCHEMA CINDER_ANALYTICS.PERF_FIXTURE TO ROLE CINDER_DBT_CI_ROLE;

-- FUTURE grants matter more than the ALL grants above. A production deploy runs
-- CREATE OR REPLACE, and a replaced object is a new object that does not inherit the old
-- object's grants. Without these, the gate works until the next merge to main and then
-- starts failing on exactly the models that just changed.
GRANT SELECT ON FUTURE TABLES         IN SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA CINDER_ANALYTICS.MARTS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA CINDER_ANALYTICS.STAGING TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA CINDER_ANALYTICS.SEEDS   TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA CINDER_ANALYTICS.PERF_FIXTURE TO ROLE CINDER_DBT_CI_ROLE;

-- ACCOUNT_USAGE, for the historical baseline: what did this model cost last time it ran,
-- and did it spill to remote storage? Spill is the signal that most reliably precedes a
-- timeout, and it is only visible here.
--
-- The gate treats this view as OPTIONAL and STALE BY DESIGN. ACCOUNT_USAGE lags by up to
-- ~45 minutes, which is fine for "what did this cost historically" and useless for "what
-- did this run just do" — so the gate never uses it to measure its own execution. If the
-- grant is absent the gate reports "no baseline" and still passes; it does not fail closed
-- on a missing privilege.
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE CINDER_DBT_CI_ROLE;

-- -------------------------------------------------------------------------------------
-- Step 2 — A fixture with enough micro-partitions for pruning to mean anything
-- -------------------------------------------------------------------------------------
-- WHY A FIXTURE AT ALL. The demo's seeded data occupies six micro-partitions in total. Every
-- pruning check passes trivially at that size: a scan of 1 partition out of 1 is a full scan
-- and is also completely harmless, so the gate would report nothing and prove nothing. To
-- demonstrate that it catches a model which does not prune, there has to be something to
-- fail to prune.
--
-- WHY GENERATED IN SNOWFLAKE RATHER THAN SEEDED. `dbt seed` loads committed CSVs, and CI
-- asserts the CSVs byte-match seeds/generate_seeds.py. A fixture large enough to be useful
-- would be a multi-hundred-megabyte unreviewable diff and a permanent CI liability. So it is
-- built here, once, with GENERATOR() — a few seconds of warehouse time and nothing in git.
CREATE SCHEMA IF NOT EXISTS CINDER_RAW.FIXTURE
    COMMENT = 'Synthetic volume for the CI performance gate. Not part of the demo narrative.';

USE WAREHOUSE CINDER_DEMO_WH;

-- ORDER BY event_ts IS THE ENTIRE POINT OF THIS INSERT, not a tidy-up.
--
-- Snowflake assigns rows to micro-partitions in the order they arrive, and records the min
-- and max of every column per partition. Insert in event-time order and each partition holds
-- a narrow, non-overlapping time range, so a predicate like `event_ts >= dateadd(day, -1, ...)`
-- lets the optimiser skip almost every partition at COMPILE time — which is what shows up in
-- EXPLAIN as partitionsAssigned far below partitionsTotal.
--
-- Insert in random order and every partition spans the full time range, so no time predicate
-- can prune anything and the table is permanently a full scan. That is the failure mode the
-- gate exists to detect, and if the fixture were built that way the gate could not tell a
-- good predicate from a bad one — everything would look equally bad.
--
-- ~50M rows, deliberately WIDE. Enough for several hundred micro-partitions, so a pruning
-- ratio is a real number rather than a rounding artefact, while keeping this to a one-off
-- build of a few minutes. Step 3 asserts that it actually landed that way — the first attempt
-- did not, and the assertion is what caught it.
CREATE OR REPLACE TABLE CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME (
    EVENT_ID     NUMBER       NOT NULL,
    JOB_ID       VARCHAR      NOT NULL,
    EVENT        VARCHAR      NOT NULL,
    QUEUE_SLUG   VARCHAR,
    ACTOR_EMAIL  VARCHAR,
    EVENT_TS     TIMESTAMP_NTZ NOT NULL,  -- when it happened: the prunable column
    IMPORT_TS    TIMESTAMP_NTZ NOT NULL,  -- when we received it: deliberately NOT prunable
    PAYLOAD      VARIANT
)
COMMENT = 'Synthetic event volume for the CI performance gate. Inserted in EVENT_TS order so that time predicates can prune.'
AS
SELECT
    seq                                                              AS event_id,
    'job_' || TO_VARCHAR(MOD(ABS(HASH(seq)), 12000000) + 1)          AS job_id,
    CASE MOD(seq, 7) WHEN 0 THEN 'job.closed' ELSE 'job.actioned' END AS event,
    'queue_' || TO_VARCHAR(MOD(seq, 40))                             AS queue_slug,
    'reviewer' || TO_VARCHAR(MOD(seq, 2500)) || '@example.com'       AS actor_email,
    event_ts,
    -- Import lags the event by a deterministic pseudo-random 0-72 hours. This is what makes
    -- an ingestion-time watermark quietly wrong for late-arriving data, and it is why the
    -- gate checks whether the watermark PRUNES rather than trying to judge which column is
    -- semantically right.
    --
    -- HASH rather than RANDOM: RANDOM() requires a constant seed, so it cannot vary per row
    -- deterministically. HASH(seq) can, which means this fixture rebuilds identically — worth
    -- having when a threshold is tuned against it.
    DATEADD(minute, MOD(ABS(HASH(seq, 'lag')), 4321), event_ts)      AS import_ts,
    -- HIGH-ENTROPY FILLER, AND IT IS LOAD-BEARING. The first attempt at this fixture used 50M
    -- narrow rows and produced 0.74 GiB in 48 micro-partitions — too few for a pruning ratio
    -- to be a meaningful number, because skipping 40 of 48 partitions and skipping 400 of 480
    -- are very different claims about a production table.
    --
    -- Micro-partition count follows BYTES, not rows, so the cheap fix is a wider row rather
    -- than four times as many. SHA2 output is effectively incompressible, so these columns
    -- cannot be squeezed away the way repeated literals were — which is the point. Real event
    -- payloads carry ids, hashes and free text and behave the same way.
    OBJECT_CONSTRUCT(
        'job_id',     'job_' || TO_VARCHAR(MOD(ABS(HASH(seq)), 12000000) + 1),
        'queue_slug', 'queue_' || TO_VARCHAR(MOD(seq, 40)),
        'trace_id',   SHA2(seq),
        'span_id',    SHA2(seq + 1),
        'content_fingerprint', SHA2(seq + 2),
        'reviewer_note', SHA2(seq + 3) || SHA2(seq + 4),
        'notes',      'synthetic fixture row'
    )                                                                AS payload
FROM (
    SELECT
        seq4() AS seq,
        -- Spread evenly across two years, monotonic in seq, so partition boundaries follow
        -- event time.
        DATEADD(second, seq4() * 1, '2024-01-01'::TIMESTAMP_NTZ) AS event_ts
    FROM TABLE(GENERATOR(ROWCOUNT => 50000000))
)
ORDER BY event_ts;

GRANT USAGE  ON SCHEMA CINDER_RAW.FIXTURE                        TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON ALL TABLES    IN SCHEMA CINDER_RAW.FIXTURE       TO ROLE CINDER_DBT_CI_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CINDER_RAW.FIXTURE       TO ROLE CINDER_DBT_CI_ROLE;
GRANT USAGE  ON SCHEMA CINDER_RAW.FIXTURE                        TO ROLE CINDER_DBT_PROD_ROLE;
GRANT SELECT ON ALL TABLES    IN SCHEMA CINDER_RAW.FIXTURE       TO ROLE CINDER_DBT_PROD_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CINDER_RAW.FIXTURE       TO ROLE CINDER_DBT_PROD_ROLE;

-- -------------------------------------------------------------------------------------
-- Step 3 — Assert the fixture is actually useful, rather than assuming it
-- -------------------------------------------------------------------------------------
-- A fixture that did not land in enough partitions makes every downstream threshold
-- meaningless while still looking like it worked. Check it, do not trust it.

-- The authoritative read: total partitions, and how well clustered the table is on the
-- column the gate expects to prune on. `total_partition_count` is the number that matters —
-- expect several hundred. If it comes back in single digits the ORDER BY was dropped or the
-- row count was reduced, and every pruning threshold downstream is theatre.
--
-- `average_overlaps` near 0 means the event-time ranges barely overlap between partitions,
-- which is what allows compile-time pruning.
SELECT SYSTEM$CLUSTERING_INFORMATION('CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME', '(EVENT_TS)') AS event_ts_clustering;

-- And the same for the ingestion timestamp — expected to be MUCH worse, because import_ts
-- was scattered by a random lag. The contrast is the demo: the same table prunes well on one
-- timestamp and badly on the other.
SELECT SYSTEM$CLUSTERING_INFORMATION('CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME', '(IMPORT_TS)') AS import_ts_clustering;

SELECT table_name, row_count, bytes, ROUND(bytes / POWER(1024, 3), 2) AS gib
FROM CINDER_RAW.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'FIXTURE';

-- Prove the pruning story end to end, without executing anything. The first plan should
-- show partitionsAssigned far below partitionsTotal; the second should show a full scan,
-- because a function wrapped around the column defeats pruning entirely.
EXPLAIN USING JSON
SELECT COUNT(*) FROM CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME
WHERE EVENT_TS >= '2025-12-01'::TIMESTAMP_NTZ;

EXPLAIN USING JSON
SELECT COUNT(*) FROM CINDER_RAW.FIXTURE.JOB_EVENTS_VOLUME
WHERE DATE_TRUNC('day', EVENT_TS) >= '2025-12-01'::TIMESTAMP_NTZ;

-- -------------------------------------------------------------------------------------
-- Verify the grants
-- -------------------------------------------------------------------------------------
SHOW GRANTS TO ROLE CINDER_DBT_CI_ROLE;
