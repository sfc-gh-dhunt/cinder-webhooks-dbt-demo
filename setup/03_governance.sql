-- =====================================================================================
-- 03 — Governance: classification and PII masking
-- =====================================================================================
-- Personal data in this pipeline is awkward for one specific reason, and it is worth being
-- clear about it before any policy is written:
--
--   THE PERSONAL DATA IS INSIDE A VARIANT WHOSE KEYS VARY BY ENTITY SCHEMA.
--
-- A `user` entity carries email, username, first and last name. A `text_post` carries a
-- caption that may contain anything at all. A customer-defined schema carries whatever was
-- defined. There is no fixed column list to protect, which means column-level masking alone
-- is not sufficient — it protects what you thought of and silently misses the rest.
--
-- So this script does two different things, and both are necessary:
--
--   1. Tag-driven column masking on the EXTRACTED columns in the marts. Precise, readable,
--      and what most consumers actually query.
--   2. VARIANT handling for the attribute bags and the raw payload. Allowlisted in the
--      marts, withheld entirely in raw — the safety net for attributes nobody enumerated.
--
-- Neither replaces the other. Applying only the first leaves the raw payload fully exposed
-- to anyone with SELECT on the landing table; applying only the second leaves the marts
-- unprotected and is unreadable in a BI tool.
--
-- Run as ACCOUNTADMIN, or a role holding CREATE TAG, CREATE MASKING POLICY and
-- APPLY MASKING POLICY.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE CINDER_DEMO_WH;
USE SCHEMA CINDER_ANALYTICS.ADMIN;

-- -------------------------------------------------------------------------------------
-- Step 1 — A role that is allowed to see personal data
-- -------------------------------------------------------------------------------------
-- Masking policies need something to test against. Defining a dedicated role rather than
-- naming individuals means the policy never has to change when the team does.
CREATE ROLE IF NOT EXISTS CINDER_PII_READER
    COMMENT = 'May see unmasked personal data in Cinder moderation data';

GRANT USAGE ON WAREHOUSE CINDER_DEMO_WH TO ROLE CINDER_PII_READER;
GRANT USAGE ON DATABASE CINDER_ANALYTICS TO ROLE CINDER_PII_READER;
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_PII_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_PII_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_PII_READER;

-- -------------------------------------------------------------------------------------
-- Step 2 — A user-defined tag for personal data
-- -------------------------------------------------------------------------------------
-- Tag-based masking, not direct attachment. The difference matters at scale: attaching a
-- policy to each column means every new column is unprotected until someone remembers it.
-- Attaching the policy to a TAG means protection follows the tag, and tagging can be
-- automated by classification.
CREATE TAG IF NOT EXISTS CINDER_ANALYTICS.ADMIN.PII_CATEGORY
    ALLOWED_VALUES 'EMAIL', 'NAME', 'USERNAME', 'IDENTIFIER', 'FREE_TEXT'
    COMMENT = 'Category of personal data held in a column. Drives tag-based masking.';

-- -------------------------------------------------------------------------------------
-- Step 3 — One masking policy, branching on the tag value
-- -------------------------------------------------------------------------------------
-- A CONSTRAINT WORTH KNOWING BEFORE YOU DESIGN THIS: a tag can carry only ONE masking
-- policy per data type. You cannot attach four VARCHAR policies to one tag and have the tag
-- value select between them — Snowflake rejects it as ambiguous.
--
-- So the branching moves inside a single policy, which reads the tag's VALUE on the column
-- it is protecting via SYSTEM$GET_TAG_ON_CURRENT_COLUMN. One policy, five treatments,
-- selected by how the column was tagged.
--
-- This is better than one-tag-per-category anyway: adding a treatment means editing one
-- policy rather than creating a tag, a policy, and an attachment, and keeping three things
-- in step forever.
--
-- The masked forms differ per category on purpose. A masked email should still look like an
-- email so a BI tool does not break on it; an identifier should stay joinable; free text
-- should reveal nothing at all.
-- Created as a stub, then given its body by ALTER. This is the re-runnable pattern:
-- CREATE OR REPLACE fails outright once a policy is attached to a column, so a setup script
-- that used it could be run exactly once. IF NOT EXISTS plus SET BODY can be run any number
-- of times, and updates an existing policy in place without detaching it first.
CREATE MASKING POLICY IF NOT EXISTS CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT
    AS (val VARCHAR) RETURNS VARCHAR -> val
    COMMENT = 'Placeholder body — set immediately below';

ALTER MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT SET BODY ->
        CASE
            -- Privileged readers see everything. Kept first so the common privileged path
            -- costs one role check and no tag lookup.
            WHEN IS_ROLE_IN_SESSION('CINDER_PII_READER') THEN val
            WHEN val IS NULL THEN NULL

            ELSE
                CASE SYSTEM$GET_TAG_ON_CURRENT_COLUMN('CINDER_ANALYTICS.ADMIN.PII_CATEGORY')

                    -- Preserve the domain: it distinguishes vendor moderators from in-house
                    -- and is not itself identifying.
                    WHEN 'EMAIL' THEN
                        CASE
                            WHEN POSITION('@' IN val) > 0 THEN '***@' || SPLIT_PART(val, '@', 2)
                            ELSE '***'
                        END

                    -- No fragment of a personal name is analytically useful, and initials are
                    -- more identifying than people assume in a small moderation team.
                    WHEN 'NAME' THEN '*** REDACTED ***'

                    WHEN 'USERNAME' THEN '*** REDACTED ***'

                    -- Hashed, not blanked. A hash keeps the column joinable and countable —
                    -- "this account was actioned nine times" still works — without revealing
                    -- which account. Blanking destroys that, and blanking is the more common
                    -- mistake.
                    WHEN 'IDENTIFIER' THEN SHA2(val, 256)

                    -- User-generated content under moderation is the highest-risk field in
                    -- the pipeline: it may contain anything, including third-party personal
                    -- data and the abuse itself. Length is retained because "how long are the
                    -- posts we action" is a legitimate question that needs no content.
                    WHEN 'FREE_TEXT' THEN '*** ' || LENGTH(val) || ' CHARS REDACTED ***'

                    -- Untagged or unrecognised: redact. Failing closed is the only safe
                    -- default for a policy attached by tag — a typo in a tag value must not
                    -- silently expose a column.
                    ELSE '*** REDACTED ***'
                END
        END;

ALTER MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT SET COMMENT = 'Masks text columns according to their PII_CATEGORY tag value. Fails closed on an unrecognised value.';

-- -------------------------------------------------------------------------------------
-- Step 4 — VARIANT redaction for payloads and attribute bags
-- -------------------------------------------------------------------------------------
-- The safety net. A VARIANT masking policy applies to the whole object, so this is the only
-- thing standing between an unprivileged reader and every attribute nobody enumerated.
--
-- Same tag, different data type — which is allowed, and is why one tag can drive both.
-- Created as a stub, then given its body by ALTER. This is the re-runnable pattern:
-- CREATE OR REPLACE fails outright once a policy is attached to a column, so a setup script
-- that used it could be run exactly once. IF NOT EXISTS plus SET BODY can be run any number
-- of times, and updates an existing policy in place without detaching it first.
CREATE MASKING POLICY IF NOT EXISTS CINDER_ANALYTICS.ADMIN.MASK_PII_VARIANT
    AS (val VARIANT) RETURNS VARIANT -> val
    COMMENT = 'Placeholder body — set immediately below';

ALTER MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_VARIANT SET BODY ->
        CASE
            WHEN IS_ROLE_IN_SESSION('CINDER_PII_READER') THEN val
            WHEN val IS NULL THEN NULL

            ELSE
                -- An ALLOWLIST, not a blocklist. A blocklist protects what you listed; an
                -- allowlist protects everything you did not. For an open-ended structure
                -- whose keys vary by entity schema, only the allowlist is safe — and this is
                -- the whole reason the attribute bag is the hard part of this pipeline.
                OBJECT_CONSTRUCT_KEEP_NULL(
                      'id', SHA2(val:id::VARCHAR, 256)
                    , 'created', val:created
                    , 'media_count', val:media_count
                    , 'duration_seconds', val:duration_seconds
                    , 'account_age_days', val:account_age_days
                    , 'transcript_available', val:transcript_available
                    , '_redacted', 'keys not on the allowlist were removed'
                )
        END;

ALTER MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_VARIANT SET COMMENT = 'Allowlists non-personal keys in a VARIANT; removes everything else';

-- The raw payload gets no allowlist at all — it is withheld whole.
--
-- Selective redaction of a webhook payload cannot be complete: any key-name-based rule
-- matches names, not values, so a free-text field called `content` holding an email address
-- passes straight through. Partial redaction of an open-ended structure invites the
-- assumption that what remains is safe. Withholding it entirely does not.
-- Created as a stub, then given its body by ALTER. This is the re-runnable pattern:
-- CREATE OR REPLACE fails outright once a policy is attached to a column, so a setup script
-- that used it could be run exactly once. IF NOT EXISTS plus SET BODY can be run any number
-- of times, and updates an existing policy in place without detaching it first.
CREATE MASKING POLICY IF NOT EXISTS CINDER_ANALYTICS.ADMIN.MASK_RAW_PAYLOAD
    AS (val VARIANT) RETURNS VARIANT -> val
    COMMENT = 'Placeholder body — set immediately below';

ALTER MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_RAW_PAYLOAD SET BODY ->
        CASE
            WHEN IS_ROLE_IN_SESSION('CINDER_PII_READER') THEN val
            WHEN val IS NULL THEN NULL
            ELSE TO_VARIANT('*** PAYLOAD WITHHELD — REQUIRES CINDER_PII_READER ***')
        END;

ALTER MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_RAW_PAYLOAD SET COMMENT = 'Withholds raw webhook payloads from readers without CINDER_PII_READER';

-- -------------------------------------------------------------------------------------
-- Step 5 — Attach both policies to the tag
-- -------------------------------------------------------------------------------------
-- Two policies, two distinct data types, one tag. From here on, tagging a column protects
-- it — no further policy work is needed for new columns or new tables.
ALTER TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY SET
      MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT
    , MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_PII_VARIANT;

-- -------------------------------------------------------------------------------------
-- Step 6 — Tag the columns
-- -------------------------------------------------------------------------------------
-- Applied to the marts, which is where analysts read. Tagging is idempotent.
--
-- NOTE ON REBUILD BEHAVIOUR: these tables are rebuilt by dbt. A CREATE OR REPLACE drops
-- column tags with it, so this step must run after each full rebuild of a tagged table. The
-- deploy target in the Makefile chains it for that reason, and it is why tag-based masking
-- is worth the setup — reapplying five tags is tractable, reapplying dozens of individual
-- policy attachments is not.

-- Moderator identity.
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_REVIEWER
    MODIFY COLUMN REVIEWER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_REVIEWER
    MODIFY COLUMN REVIEWER_NAME SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'NAME';

-- Entity identity and content. `entity_id` is hashed rather than blanked so it stays
-- joinable and countable.
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_USERNAME SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'USERNAME';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_CAPTION SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'FREE_TEXT';
ALTER TABLE CINDER_ANALYTICS.MARTS.DIM_ENTITY
    MODIFY COLUMN ENTITY_ATTRIBUTES SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'IDENTIFIER';

-- Moderator emails carried on the facts as degenerate dimensions. Easy to forget, and they
-- are the same personal data as in the dimension.
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_DECISIONS
    MODIFY COLUMN REVIEWER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOB_ACTIONS
    MODIFY COLUMN ACTOR_USER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';
ALTER TABLE CINDER_ANALYTICS.MARTS.FCT_JOBS
    MODIFY COLUMN FINAL_REVIEWER_EMAIL SET TAG CINDER_ANALYTICS.ADMIN.PII_CATEGORY = 'EMAIL';

-- -------------------------------------------------------------------------------------
-- Step 7 — Protect the raw payloads directly
-- -------------------------------------------------------------------------------------
-- The landing tables are not rebuilt by dbt, so a direct policy attachment is appropriate
-- here and is more durable than a tag.
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED
    MODIFY COLUMN PAYLOAD SET MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_RAW_PAYLOAD;
ALTER TABLE CINDER_RAW.OPENFLOW_CINDER.JOB_CLOSED
    MODIFY COLUMN PAYLOAD SET MASKING POLICY CINDER_ANALYTICS.ADMIN.MASK_RAW_PAYLOAD;

-- IMPORTANT — the dbt role must be able to read the payload, or every model breaks. The
-- policy tests role membership, so the transformation role has to be in CINDER_PII_READER.
-- This is a real trade-off and not a technicality: the role that builds the marts can see
-- everything by construction. Constrain it by limiting who can assume it, not by masking
-- the data it needs to read.
GRANT ROLE CINDER_PII_READER TO ROLE CINDER_DBT_PROD_ROLE;
GRANT ROLE CINDER_PII_READER TO ROLE CINDER_DBT_CI_ROLE;

-- -------------------------------------------------------------------------------------
-- Step 8 — Automatic classification
-- -------------------------------------------------------------------------------------
-- Everything above is manual: someone decided which columns hold personal data. That does
-- not survive contact with a schema that keeps changing.
--
-- A classification profile scans on a schedule, infers semantic categories, and can apply
-- tags automatically. Set AUTO_TAG to TRUE and Snowflake's own SNOWFLAKE.CORE tags are
-- applied without anyone remembering to.
--
-- The two tag systems coexist and complement each other. Snowflake's classification applies
-- its own SEMANTIC_CATEGORY and PRIVACY_CATEGORY tags; the user-defined PII_CATEGORY tag
-- above is what drives THIS project's masking. To drive masking from classification instead,
-- attach the policies to SNOWFLAKE.CORE.PRIVACY_CATEGORY as well.
--
-- Classification cannot see inside a VARIANT, which is the important caveat: it will find
-- the extracted email column and will not find the email inside the payload. The VARIANT
-- policies above remain necessary.
CREATE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE IF NOT EXISTS
    CINDER_ANALYTICS.ADMIN.CINDER_CLASSIFICATION_PROFILE(
        {
            'minimum_object_age_for_classification_days': 0,
            'maximum_classification_validity_days': 30,
            'auto_tag': TRUE
        }
    );

-- Attach to the marts schema so new tables are classified as they appear.
ALTER SCHEMA CINDER_ANALYTICS.MARTS
    SET CLASSIFICATION_PROFILE = 'CINDER_ANALYTICS.ADMIN.CINDER_CLASSIFICATION_PROFILE';

-- -------------------------------------------------------------------------------------
-- Step 9 — A role for testing the masked view
-- -------------------------------------------------------------------------------------
-- You cannot claim a masking policy works until you have seen it from both sides. This role
-- exists to make that possible without inventing a throwaway user.
CREATE ROLE IF NOT EXISTS CINDER_ANALYST_NO_PII
    COMMENT = 'Reads Cinder analytics WITHOUT access to personal data. Use it to verify masking.';

GRANT USAGE ON WAREHOUSE CINDER_DEMO_WH TO ROLE CINDER_ANALYST_NO_PII;
GRANT USAGE ON DATABASE CINDER_ANALYTICS TO ROLE CINDER_ANALYST_NO_PII;
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_ANALYST_NO_PII;
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_ANALYST_NO_PII;
GRANT SELECT ON ALL TABLES IN SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_ANALYST_NO_PII;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CINDER_ANALYTICS.MARTS TO ROLE CINDER_ANALYST_NO_PII;
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_ANALYST_NO_PII;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_ANALYST_NO_PII;

-- =====================================================================================
-- Verification
-- =====================================================================================
--
-- ####################################################################################
-- # THE TRAP: SECONDARY ROLES WILL MAKE YOU THINK YOUR MASKING IS BROKEN             #
-- ####################################################################################
--
-- These policies test role membership with IS_ROLE_IN_SESSION. Snowflake now enables all
-- of a user's granted roles as SECONDARY roles by default (DEFAULT_SECONDARY_ROLES = ALL).
--
-- IS_ROLE_IN_SESSION is satisfied by ANY role active in the session, primary OR secondary.
-- So a user who holds CINDER_PII_READER through ANY grant — including one they are not
-- currently using as their primary role — sees unmasked data no matter which role they
-- switch to.
--
-- The practical consequences, both of which matter:
--
--   1. WHEN TESTING, run `USE SECONDARY ROLES NONE` first, or you will see plaintext, and
--      conclude the policy does not work when in fact it is working exactly as written.
--
--   2. IN PRODUCTION, treat membership of CINDER_PII_READER as the whole of the access
--      decision. Switching primary role away from it does not remove the privilege. If you
--      need stricter separation, either do not grant the role to users who should not have
--      it, or set DEFAULT_SECONDARY_ROLES = () on those users.
--
-- IS_ROLE_IN_SESSION is still the right function to use, because it respects role
-- hierarchies — CURRENT_ROLE() = 'CINDER_PII_READER' would break the moment someone
-- reasonably grants the role to a parent role. The behaviour just has to be understood.
--
-- -------------------------------------------------------------------------------------
-- Confirm the tags landed where they should.
SELECT
      OBJECT_NAME
    , COLUMN_NAME
    , TAG_NAME
    , TAG_VALUE
FROM TABLE(CINDER_ANALYTICS.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
    'CINDER_ANALYTICS.MARTS.DIM_REVIEWER', 'TABLE'))
ORDER BY COLUMN_NAME;

-- Confirm the policies are attached to the tag and active.
SELECT POLICY_NAME, REF_ENTITY_NAME, REF_ENTITY_DOMAIN, POLICY_STATUS
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'CINDER_ANALYTICS.ADMIN.MASK_PII_TEXT'));

-- -------------------------------------------------------------------------------------
-- Prove the masking, from the unprivileged side. Note the USE SECONDARY ROLES NONE — see
-- the trap above. Run this block as a user holding CINDER_ANALYST_NO_PII.
--
--   USE ROLE CINDER_ANALYST_NO_PII;
--   USE SECONDARY ROLES NONE;
--   USE WAREHOUSE CINDER_DEMO_WH;
--
--   -- Expect: ***@example.com, *** REDACTED ***
--   SELECT reviewer_email, reviewer_name FROM CINDER_ANALYTICS.MARTS.DIM_REVIEWER LIMIT 3;
--
--   -- Expect: allowlisted keys only, id hashed
--   SELECT entity_username, entity_attributes FROM CINDER_ANALYTICS.MARTS.DIM_ENTITY LIMIT 3;
--
--   -- Expect: *** PAYLOAD WITHHELD ***
--   SELECT payload FROM CINDER_RAW.OPENFLOW_CINDER.JOB_ACTIONED LIMIT 1;
--
--   -- Expect: unaffected. Aggregates over masked columns still work, which is the point —
--   -- the analytics survive the masking.
--   SELECT * FROM SEMANTIC_VIEW(
--       CINDER_ANALYTICS.SEMANTIC.SEM_CINDER_MODERATION
--       DIMENSIONS queues.queue_name
--       METRICS decisions.median_handle_time_hours
--   );
--
-- Then repeat the first query as a member of CINDER_PII_READER and confirm the values differ.
-- A policy verified from only one side has not been verified.
