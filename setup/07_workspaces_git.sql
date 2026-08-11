-- =====================================================================================
-- 07 — Snowsight Workspaces: Git integration
-- =====================================================================================
-- Lets a developer open this repository directly inside Snowsight — Projects »
-- Workspaces » From Git repository — and edit, commit and push without leaving the
-- browser. Entirely optional. Nothing in the dbt project, the CI/CD pipelines or the
-- semantic view depends on it.
--
-- RUN ORDER: independent. It touches no database, schema or table, so it can run at any
-- point, before or after a build. It is numbered 07 only because it is the last thing you
-- would set up, not because anything precedes it.
--
-- ALSO AVAILABLE AS TERRAFORM. See terraform/ for an equivalent that a Terraform shop can
-- apply instead. The two are kept deliberately in step; if you change one, change the
-- other. terraform/README.md records which objects each side owns.
--
-- WHY THIS IS NOT IN 04_ci_access.sql, which also creates an API integration: different
-- audience and different lifetime. 04 exists so machines can deploy — service users, keys,
-- runner network access. This exists so humans can edit in a browser. Someone adopting the
-- CI/CD pattern needs 04 and may have no interest in this at all.
-- =====================================================================================

USE ROLE ACCOUNTADMIN;

-- -------------------------------------------------------------------------------------
-- The API integration
-- -------------------------------------------------------------------------------------
-- AUTHENTICATION IS THE ONLY REAL DECISION HERE, and it is the same trade as everywhere
-- else in this project: a stored credential versus a delegated one.
--
--   SNOWFLAKE_GITHUB_APP  OAuth2 through Snowflake's pre-registered GitHub App. Nothing
--                         stored in Snowflake, nothing to rotate, and no secret for a
--                         later mistake to leak. Used below.
--
--   Personal access token A SECRET holding a username and PAT, plus
--                         ALLOWED_AUTHENTICATION_SECRETS on the integration. Works with
--                         no browser step and no GitHub App approval, which is sometimes
--                         the deciding factor — see the fallback at the end of this file.
--
-- The GitHub App is pre-registered by Snowflake, so there is no OAuth application to
-- create, no client secret to store and no redirect URI to register. It works with
-- github.com, including standard GitHub Enterprise Cloud organisations hosted there.
-- GitHub Enterprise Cloud with data residency (*.ghe.com) and GitHub Enterprise Server
-- both need TYPE = OAUTH2 with explicit endpoints instead.
CREATE API INTEGRATION IF NOT EXISTS GITHUB_APP_INTEGRATION
    API_PROVIDER = GIT_HTTPS_API
    -- SCOPED TO ONE NAMESPACE ON PURPOSE. 'https://github.com/' would authorise every
    -- repository on GitHub for anyone in the account holding USAGE on this integration.
    -- Narrow it to the org or user that owns your repositories and add prefixes
    -- deliberately. Replace this with your own.
    API_ALLOWED_PREFIXES = ('https://github.com/YOUR_GITHUB_ORG_OR_USER')
    API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
    ENABLED = TRUE
    COMMENT = 'OAuth2 via the Snowflake GitHub App for Snowsight Workspaces. No stored token.';

-- -------------------------------------------------------------------------------------
-- Who can use it
-- -------------------------------------------------------------------------------------
-- The integration is invisible in the Workspaces dialog to any role without USAGE, and
-- the dialog gives no hint as to why — the dropdown is simply missing the entry. That is
-- the single most common reason this setup appears not to work.
--
-- ACCOUNTADMIN owns it by virtue of creating it, so ownership already implies usage.
-- Grant onward to whichever role your developers actually select in Snowsight.
GRANT USAGE ON INTEGRATION GITHUB_APP_INTEGRATION TO ROLE SYSADMIN;
-- GRANT USAGE ON INTEGRATION GITHUB_APP_INTEGRATION TO ROLE YOUR_DEVELOPER_ROLE;

-- -------------------------------------------------------------------------------------
-- The part that cannot be scripted
-- -------------------------------------------------------------------------------------
-- Neither SQL nor Terraform can finish this. Authorising the app is an OAuth consent
-- flow, so it happens in a browser, once per GitHub account:
--
--   1. Snowsight » Projects » Workspaces » From Git repository
--   2. Repository URL: the HTTPS clone URL, e.g.
--      https://github.com/YOUR_GITHUB_ORG_OR_USER/YOUR_REPO
--   3. API integration: select this integration. Choosing an integration WITHOUT
--      API_USER_AUTHENTICATION is why the dialog would otherwise offer only "Personal
--      access token" and "Public repository" — the sign-in option appears only when the
--      selected integration supports OAuth.
--   4. Sign in » Configure » Authorize Snowflake Computing
--   5. Permissions: Read access to metadata, AND Read and write access to code. Write is
--      what allows commit and push back; without it the workspace is read-only.
--   6. Repository access: prefer "Only select repositories" over "All repositories".
--
-- IF THE CLONE FAILS WITH "Operation clone is not permitted by server", the app was
-- authorised as an identity but was not granted access to that specific repository. Those
-- are two distinct steps in GitHub's flow and it is easy to complete the first and miss
-- the second. Fix it at https://github.com/settings/installations » Snowflake Computing »
-- Configure » Repository access.
--
-- IF INSTALLATION NEEDS ADMIN APPROVAL, the GitHub organisation restricts third-party
-- apps. Enterprise-managed accounts commonly do. Either get the app approved, or use the
-- token fallback below, which needs no app and no approval.

-- -------------------------------------------------------------------------------------
-- Token fallback, if the GitHub App is unavailable to you
-- -------------------------------------------------------------------------------------
-- Equivalent outcome, including push, at the cost of a long-lived credential you now own
-- and must rotate. Prefer a fine-grained token limited to the single repository with
-- Contents: Read and write, rather than a classic token carrying `repo` across everything.
--
-- CREATE SECRET CINDER_ANALYTICS.ADMIN.GITHUB_TOKEN
--     TYPE = PASSWORD
--     USERNAME = 'YOUR_GITHUB_USERNAME'
--     PASSWORD = 'YOUR_TOKEN'
--     COMMENT = 'GitHub PAT for Workspaces. Rotate on your own schedule; nothing does it for you.';
--
-- CREATE API INTEGRATION GITHUB_TOKEN_INTEGRATION
--     API_PROVIDER = GIT_HTTPS_API
--     API_ALLOWED_PREFIXES = ('https://github.com/YOUR_GITHUB_ORG_OR_USER')
--     ALLOWED_AUTHENTICATION_SECRETS = (CINDER_ANALYTICS.ADMIN.GITHUB_TOKEN)
--     ENABLED = TRUE;
--
-- Then pick "Personal access token" in the dialog and select the secret. Note the
-- integration must name the secret — or ALL — or the secret will not be offered.

-- -------------------------------------------------------------------------------------
-- Verify
-- -------------------------------------------------------------------------------------
-- USER_AUTH_TYPE = SNOWFLAKE_GITHUB_APP in the DESCRIBE output is what makes the sign-in
-- option appear. If it is absent, the dialog will only ever offer token or public.
DESCRIBE API INTEGRATION GITHUB_APP_INTEGRATION;
SHOW GRANTS ON INTEGRATION GITHUB_APP_INTEGRATION;
