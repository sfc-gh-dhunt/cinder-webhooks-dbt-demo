-- =====================================================================================
-- 04b — CI/CD access: service users, keypair auth, and network access
-- =====================================================================================
-- Everything a CI/CD pipeline needs to reach this account, and nothing more. Run once by
-- an administrator. It is separate from 01_account_setup.sql because it touches identity
-- and network controls, which usually need a different approval than creating a warehouse.
--
-- RUN ORDER: after 01_account_setup.sql (the roles must exist).
--
-- The public keys below are placeholders. Generate a keypair per user:
--
--   openssl genrsa -out ci_key.pem 2048
--   openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt \
--       -in ci_key.pem -out ci_key_pkcs8.pem
--   openssl rsa -in ci_key_pkcs8.pem -pubout -out ci_key.pub
--
-- Keep the keys OUTSIDE the repository. The private key goes into the CI secret store; the
-- public key body — the base64 between the PEM header and footer, newlines stripped — goes
-- into the ALTER USER statements below.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;

-- -------------------------------------------------------------------------------------
-- Step 1 — Service users
-- -------------------------------------------------------------------------------------
-- TYPE = SERVICE matters. It is not cosmetic: a SERVICE user cannot log in through the UI
-- and cannot use a password, so the only way in is the key. It is also exempt from MFA
-- enrolment requirements, which is what otherwise breaks automation when an account
-- tightens its authentication policy.
--
-- TWO users, not one, and they hold DIFFERENT roles. This is the point of the whole
-- exercise. Pull requests come from forks and untrusted branches; a workflow file is just
-- another file a contributor can edit. If PR validation and production deployment share one
-- identity, then anyone who can open a pull request can write to production. Splitting them
-- means the worst a PR can do is churn its own throwaway schemas.
CREATE USER IF NOT EXISTS CINDER_CI_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = CINDER_DBT_CI_ROLE
    DEFAULT_WAREHOUSE = CINDER_DEMO_WH
    COMMENT = 'Validates pull requests. Builds throwaway per-PR schemas only.';

CREATE USER IF NOT EXISTS CINDER_DEPLOY_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = CINDER_DBT_PROD_ROLE
    DEFAULT_WAREHOUSE = CINDER_DEMO_WH
    COMMENT = 'Deploys to production on merge to main. Protected by a GitHub environment.';

-- Replace with your own public key bodies.
ALTER USER CINDER_CI_SVC     SET RSA_PUBLIC_KEY = 'PASTE_CI_PUBLIC_KEY_BODY_HERE';
ALTER USER CINDER_DEPLOY_SVC SET RSA_PUBLIC_KEY = 'PASTE_DEPLOY_PUBLIC_KEY_BODY_HERE';

GRANT ROLE CINDER_DBT_CI_ROLE   TO USER CINDER_CI_SVC;
GRANT ROLE CINDER_DBT_PROD_ROLE TO USER CINDER_DEPLOY_SVC;

-- -------------------------------------------------------------------------------------
-- Step 2 — Privileges the CI role needs beyond reading and building
-- -------------------------------------------------------------------------------------
-- CI deploys its own throwaway project object, so it needs the privilege to create one.
-- Easy to miss when copying grants from the production role, and the failure arrives late —
-- after checkout, install and connection all succeed.
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.DBT TO ROLE CINDER_DBT_CI_ROLE;
GRANT CREATE DBT PROJECT ON SCHEMA CINDER_ANALYTICS.DBT TO ROLE CINDER_DBT_CI_ROLE;
GRANT CREATE STAGE ON SCHEMA CINDER_ANALYTICS.DBT TO ROLE CINDER_DBT_CI_ROLE;

-- The semantic view is a model like any other, so CI builds one too.
GRANT USAGE ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_CI_ROLE;
GRANT CREATE SEMANTIC VIEW ON SCHEMA CINDER_ANALYTICS.SEMANTIC TO ROLE CINDER_DBT_CI_ROLE;

-- -------------------------------------------------------------------------------------
-- Step 3 — Network access for the runners
-- -------------------------------------------------------------------------------------
-- THE PROBLEM. Most real accounts restrict access by IP. CI runners are ephemeral and their
-- addresses are neither stable nor yours, so every pipeline fails with:
--
--   Incoming request with IP/Token x.x.x.x is not allowed to access Snowflake
--
-- WHAT NOT TO DO. Do not widen the account-level policy. It is usually a corporate control
-- protecting every human and every service in the account, and adding thousands of public
-- cloud ranges to it removes the protection for everyone in order to unblock one pipeline.
--
-- WHAT TO DO INSTEAD, and it is better than it sounds: Snowflake MAINTAINS the address list
-- for you. SNOWFLAKE.NETWORK_SECURITY holds managed network rules for common SaaS platforms,
-- updated by Snowflake as the providers change. GITHUBACTIONS_GLOBAL carries several
-- thousand ranges. Nothing to hand-maintain and nothing to go stale.
--
--   SHOW NETWORK RULES IN SCHEMA SNOWFLAKE.NETWORK_SECURITY;
--
-- lists them — also Azure DevOps, dbt Cloud, Tableau, Power BI and others. Substitute the
-- rule matching your CI platform.
CREATE NETWORK POLICY IF NOT EXISTS CINDER_CI_GITHUB_ACTIONS_POLICY
    ALLOWED_NETWORK_RULE_LIST = ('SNOWFLAKE.NETWORK_SECURITY.GITHUBACTIONS_GLOBAL')
    COMMENT = 'Permits GitHub Actions runners. Attach to CI service users only, never to the account.';

-- ATTACHED PER USER, WHICH IS THE ENTIRE POINT. A user-level policy overrides the
-- account-level one for that user alone. Humans keep whatever restriction the account
-- imposes; these two service users — which cannot log in interactively and hold only the
-- demo roles — accept connections from CI. The account policy is left untouched.
--
-- Confirm you have not changed it:
--   SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT;
ALTER USER CINDER_CI_SVC     SET NETWORK_POLICY = CINDER_CI_GITHUB_ACTIONS_POLICY;
ALTER USER CINDER_DEPLOY_SVC SET NETWORK_POLICY = CINDER_CI_GITHUB_ACTIONS_POLICY;

-- Worth being clear-eyed: this permits any GitHub Actions runner in the world, not just
-- yours, so the key is what actually authenticates you. Guard the secret, keep the roles
-- narrow, and prefer the option below for anything long-lived.

-- -------------------------------------------------------------------------------------
-- Step 4 — The better option, once you are past the demo
-- -------------------------------------------------------------------------------------
-- Everything above depends on a long-lived private key sitting in a CI secret store. It
-- does not rotate itself, it is readable by every workflow in the repository, and it is
-- copyable — an exfiltrated key keeps working until someone notices.
--
-- Workload identity federation removes the secret entirely. The runner presents a
-- short-lived OIDC token that Snowflake validates against the provider, scoped to your
-- repository. Nothing to leak and nothing to rotate.
--
-- See .github/workflows/deploy-oidc.yml.example for the pipeline side.
--
-- CREATE SECURITY INTEGRATION GITHUB_ACTIONS_OIDC
--     TYPE = WORKLOAD_IDENTITY
--     WORKLOAD_IDENTITY_PROVIDER = 'OIDC'
--     OIDC_ISSUER = 'https://token.actions.githubusercontent.com'
--     OIDC_AUDIENCE_LIST = ('snowflakecomputing.com')
--     ENABLED = TRUE;
--
-- ALTER USER CINDER_DEPLOY_SVC SET
--     WORKLOAD_IDENTITY_SUBJECT = 'repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main';

-- -------------------------------------------------------------------------------------
-- Verify
-- -------------------------------------------------------------------------------------
SHOW USERS LIKE 'CINDER%SVC';
SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT;
