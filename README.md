# Cinder webhooks → dbt on Snowflake

A complete, runnable demo of modelling Trust & Safety moderation events with **dbt Projects on
Snowflake**: raw webhook payloads in, dimensional model and Cortex Analyst semantic view out,
with tests, PII masking, monitoring and CI along the way.

Clone it, run three commands, and you have a working pipeline you can query in natural
language. No ingestion pipeline required — it ships with synthetic data.

---

## What this is

[Cinder](https://docs.cinder.ai) is a Trust & Safety platform: content and accounts are
reviewed in queues, moderators make decisions against a policy tree, and enforcement actions
follow. It emits webhooks as those things happen.

This project models two of those webhook events:

| Event | What it means |
|---|---|
| `job.actioned` | A review job moved — escalated, requeued, skipped, deferred, cancelled |
| `job.closed` | A review job was resolved, carrying the decisions that resolved it |

From those two it builds a dimensional model that answers the questions moderation teams
actually ask:

- How many jobs are closed each day?
- Who are the top moderators by activity, and how many are active each day?
- What is the distribution of moderation policies?
- What is handle time per decision, by queue, by moderator, by content type?
- What is the median time to close a job?
- What share of jobs are closed by an automated decision?
- How many queue changes does a job undergo before it closes?
- Do some moderators have a best queue in terms of handle time?

Every one of those is encoded as a verified query in the semantic view, so Cortex Analyst
answers them without being asked twice.

## What it demonstrates

- **dbt as a native Snowflake object** — deployed with `snow dbt deploy`, versioned, run by a
  Snowflake task
- **A semantic view in version control** — the semantic layer is a dbt model in the same DAG
  as the marts that feed it, so a column rename and its exposure move in one commit
- **Modelling semi-structured events honestly** — VARIANT payloads, arrays flattened to their
  correct grain, deduplication without a delivery identifier
- **An accumulating snapshot** — the job-grain fact that makes cross-event questions answerable
- **Tag-driven PII masking** over personal data that lives inside a VARIANT whose keys vary by
  content type
- **A defensible split between dbt tests and Snowflake data metric functions**
- **CI/CD assembled from primitives**, because Snowflake-native dbt has none built in

---

## Quickstart

Prerequisites: [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index)
with a working connection, a role that can create databases and integrations, and Python 3.11+.

```bash
# 1. Databases, schemas, warehouse, roles, the external access integration, the PII tag
#    and masking policies. Everything that can exist before there is any data.
make setup

# 2. Deploy the dbt project into Snowflake, run it there, and reapply the PII column tags.
make deploy-run

# 3. Data metric functions, the scheduled task and the alerts. These attach to tables that
#    step 2 creates, which is why they come after it rather than as part of step 1.
make setup-post-build

# 4. Ask it something.
make verify-semantic-view
```

That is the whole path from empty account to queryable semantic view. It takes a few minutes,
almost all of it waiting on `dbt deps` inside Snowflake.

**Why setup is two steps.** Half of what this project creates attaches to tables dbt builds —
column tags, and data metric functions on the marts. Those cannot be created on an empty
account, so a single `make setup` would fail partway through and leave the task and the alerts
uncreated with no obvious cause. The numbering follows the same split: `setup/01`–`04` run
before the first build, `05` and `06` after it.

**The external access integration is not optional.** `make setup` creates
`CINDER_DEMO_DBT_EAI`, allowing egress to `hub.getdbt.com` and `codeload.github.com`. Snowflake
resolves dbt packages *itself* at deploy time — `packages.yml` pulls `dbt_utils` and
`dbt_semantic_view` — and without the EAI attached to the project object, `snow dbt deploy`
fails to resolve them. Every deploy path passes it: `make deploy`, both workflows, and the
`deploy-oidc` example. If you rename it, set a `SNOWFLAKE_EAI` repository variable to match, or
CI will keep asking for the old name while `make deploy` carries on working.

Nothing runs on a schedule until you ask it to. The task and both alerts are created
**suspended**, so a fresh account does not start consuming credits the moment it is set up:

```bash
make resume-operations   # and make suspend-operations to stop again
```

`make help` lists everything else.

### Developing locally

Deploying on every change is slow. For a normal edit-test loop, run dbt locally against the
same Snowflake objects:

```bash
make dev-profile   # writes a profile OUTSIDE the repo, so credentials cannot be committed
make deps
make build         # build and test everything
```

Then `make deploy` when you are ready to publish.

---

## How it fits together

```
Cinder webhooks
      │
      ▼
CINDER_RAW.OPENFLOW_CINDER          one table per event type
  JOB_ACTIONED  ┐                   EVENT / PAYLOAD / IMPORT_TS
  JOB_CLOSED    ┘
      │
      ▼
CINDER_ANALYTICS
  SEEDS         synthetic payloads, so the project runs with no real data
      │
      ▼
  STAGING       base_*   resolve seeds-or-raw, deduplicate
                stg_*    flatten each event to its own grain
      │
      ▼
  MARTS         dim_queue  dim_policy  dim_reviewer  dim_entity
                dim_workflow  dim_enforcement_action
                fct_jobs          one row per job (accumulating snapshot)
                fct_decisions     one row per decision
                fct_decision_policies
                fct_job_actions
      │
      ▼
  SEMANTIC      sem_cinder_moderation → Cortex Analyst
```

### Four grains, kept apart

A job closes once, is decided one or more times, applies one or more policies per decision, and
is actioned many times. Those are four different grains and they are four different tables.

Collapsing them into one wide table is the most tempting shortcut here and the most damaging.
A job with three queue changes would contribute its handle time three times, and "average
handle time" would be quietly, unfixably wrong — while still looking entirely reasonable.

So: `decision_count` is only ever summed from `fct_decisions`. Policy volume is only ever
summed from `fct_decision_policies`. `fct_jobs` is the only place the cross-event lifecycle
measures exist, because neither event carries both halves — actions know the movement history
but not the outcome, closures know the outcome but not the movement history.

---

## Six things about this data that will catch you out

These are the reasons the models look the way they do. Every one produces wrong answers
silently if ignored, which is the dangerous kind.

### 1. There is no webhook delivery identifier

Cinder's webhooks carry no delivery ID, and the idempotency documentation covers inbound API
requests rather than outbound deliveries. So there is nothing to deduplicate on.

This project synthesises one: a hash of the event name and the payload
(`macros/cinder_helpers.sql`). The ingestion timestamp is deliberately **excluded** — a
redelivery gets a different ingestion time, so including it would give the duplicate a
different hash and defeat the whole purpose.

The limitation, stated because it is real: two genuinely distinct events with byte-identical
payloads collapse into one row. Payloads carry microsecond timestamps, so this is vanishingly
unlikely — but it is a property of the design, not an accident. If Cinder ever exposes a
delivery ID, replace that one macro and everything downstream inherits the improvement.

### 2. `IMPORT_TS` is not event time

It is ingestion wall-clock, second resolution, no timezone. Event time is `payload.timestamp`
and is timezone-aware.

Using the ingestion timestamp as event time is the single most common mistake with this shape
of landing table. It is used here only for ingestion lineage and incremental watermarking —
which is the *correct* watermark for a webhook feed, because a redelivery or a late
subscription can bring in an event timestamped earlier than anything already loaded, and an
event-time watermark would skip it silently.

### 3. Closure counts understate closures

Cinder sends **no** `job.closed` event when a job closes with zero production decisions. So
closure counts are a floor, not a total, and `is_open` on `fct_jobs` means "no closure event
seen" rather than "definitely still in the queue".

Nothing in a data model can fix this — it is a property of the event surface. It is documented
on the model and asserted as a warning-level test rather than papered over.

### 4. The documented enums are incomplete

Production payloads carry values the documentation does not list — `job_category` values
outside the published four, actions the prose omits but the schema includes.

So every `accepted_values` test in this project is **`severity: warn`**. They exist to tell you
when something new appears, not to assert a contract. An error-severity enum test here would
fail your build on entirely valid data, and the natural response to that — deleting the test —
loses the signal altogether.

### 5. Field names and enums drift between events

The same concept is `job_category` on `job.actioned` and `category` on `job.closed`, and the
second carries a wider enum. Normalised in staging by `cinder_normalised_job_category`, with
the accepted-values test asserting the union of both.

### 6. Personal data lives inside a VARIANT whose keys vary

A `user` entity carries email, username and names. A `text_post` carries a caption that may
contain anything. A customer-defined schema carries whatever was defined.

There is no fixed column list to protect. This is why `dim_entity.entity_attributes` stays a
VARIANT — flattening it to fixed columns would break on the first new content type and
silently discard unmapped attributes until then — and it is why the governance layer needs
both column masking and VARIANT handling.

---

## Governance

`setup/03_governance.sql`. Two mechanisms, because neither is sufficient alone.

**Tag-driven column masking** on the extracted columns. One tag (`PII_CATEGORY`) with five
values, and **one** masking policy that branches on the tag's value.

Why one policy and not five: a tag can carry only one masking policy *per data type*. Attaching
four VARCHAR policies to one tag is rejected as ambiguous. So the branching moves inside the
policy, via `SYSTEM$GET_TAG_ON_CURRENT_COLUMN`.

The masked forms differ on purpose. Emails keep their domain, so vendor-versus-in-house
analysis still works. Identifiers are hashed rather than blanked, so they stay joinable and
countable — you can still say "this account was actioned nine times" without knowing which
account. Free text is redacted but its length is preserved.

**VARIANT handling** for the attribute bags and the raw payloads. The attribute bag gets an
**allowlist** — a blocklist protects what you listed, an allowlist protects everything you did
not, and only the second is safe for an open-ended structure. The raw payload is withheld
whole, because any key-name rule matches names rather than values: a field called `content`
holding an email address passes straight through, and partial redaction invites the assumption
that what remains is safe.

### Two traps worth knowing before you test this

**Secondary roles will make you think your masking is broken.** The policies test membership
with `IS_ROLE_IN_SESSION`, and Snowflake activates all of a user's granted roles as *secondary*
roles by default. `IS_ROLE_IN_SESSION` is satisfied by any of them, so a user who holds
`CINDER_PII_READER` through any grant sees plaintext no matter which primary role they switch
to. Run `USE SECONDARY ROLES NONE` when testing — `make verify-masking` does. In production,
treat membership of that role as the whole access decision.

**A dbt rebuild drops column tags.** dbt uses `CREATE OR REPLACE`, which takes the tags with
it, and the masking policies are attached *by tag*. An untagged column is an unmasked column.
`make deploy-run` and the deploy workflow both reapply `setup/05_apply_column_tags.sql` for exactly
this reason. It is idempotent and cheap; forgetting it is a data-protection incident.

---

## Testing and monitoring

Two surfaces, split on one axis, with one deliberate overlap.

**dbt tests own logic, at build time.** Surrogate key uniqueness, referential integrity,
accepted values, business invariants. These are properties of the transformation, so they live
with the code that creates it and they block a bad build.

The singular tests in `tests/` are the interesting ones. `assert_decisions_not_before_job_creation`
catches timezone errors in a way a range check never would: both timestamps are individually
plausible, and only their *order* reveals the bug. `assert_decision_counts_agree_across_grains`
asserts that policy distribution sums back to the decision total, because a distribution that
does not add up is how a dimensional model loses its users' trust.

**Data metric functions own state, continuously.** Freshness and row volume on the landing
tables, row count and null rate on the facts behind the semantic view.
`setup/04_operations.sql`.

These must fire when *no build is running*. If ingestion stops at 03:00 and dbt is not
scheduled until 06:00, no dbt test will ever notice — there is nothing to run. Meanwhile every
dashboard keeps returning yesterday's answer, confidently and without error. That is the
failure mode DMFs catch and dbt cannot.

The dividing question: *would I want to know about this even if the pipeline never ran again?*
If yes, it is a DMF.

**Freshness is asserted on both sides, deliberately** — as a dbt source freshness gate (do not
rebuild on stale data) and as a DMF (tell someone at 03:00). Same assertion, two consumers,
neither able to do the other's job. Nothing else is duplicated; there are no null or uniqueness
checks on both surfaces.

Two limits of DMFs, found the hard way and documented in the script: `FRESHNESS` has no
`TIMESTAMP_NTZ` overload (which is what the ingestion layer writes), and there are no VARIANT
overloads at all. Anything VARIANT-shaped stays with dbt.

---

## CI/CD

Snowflake-native dbt has **no built-in CI/CD**. Auto-deploy, PR validation and scheduled
refresh are assembled from primitives: the project object, the `snow` CLI, `EXECUTE DBT PROJECT`
and Tasks. `.github/workflows/` is that assembly.

**`ci.yml`** on every pull request: lint, assert the committed seeds match their generator,
parse without a warehouse, then build and test against Snowflake in schemas namespaced by PR
number, and drop them again — including on failure.

**`deploy.yml`** on merge to main: publish a new version of the project object and reapply the
column tags. It deliberately does *not* run the models; the scheduled task does that. A deploy
that also ran a full production rebuild at merge time, competing with the schedule, is not what
anyone wants.

**`deploy-oidc.yml.example`** is the same thing with workload identity federation instead of a
stored key — no long-lived secret, no rotation. It is the better choice for anything permanent.
Key pair is the active default only because it works with no identity-provider setup.

### Setting it up in your own account

Four steps. Nothing here is specific to a particular Snowflake account or GitHub organisation.

**1. Generate a keypair.** Outside the repository — this must never be committed.

```bash
mkdir -p ~/.snowflake-keys && cd ~/.snowflake-keys
openssl genrsa -out ci_key.pem 2048
openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in ci_key.pem -out ci_key_pkcs8.pem
openssl rsa -in ci_key_pkcs8.pem -pubout -out ci_key.pub
chmod 600 ci_key*
```

**2. Create the service users.** Paste the public key body — the base64 between the PEM header
and footer, newlines stripped — over the two placeholders in `setup/04_ci_access.sql`, then:

```bash
make setup-ci-access
```

That creates `CINDER_CI_SVC` (validates pull requests) and `CINDER_DEPLOY_SVC` (deploys on
merge), each holding exactly one role. **Two users, not one, and this is the point:** a workflow
file is just another file a contributor can edit, and pull requests run on untrusted branches.
If validation and deployment share an identity, anyone who can open a pull request can write to
production. Split, the worst a PR can do is churn its own throwaway schemas.

It also grants network access, which is the step most accounts trip over — see below.

**3. Tell GitHub about it.**

```bash
gh variable set SNOWFLAKE_ACCOUNT   --body "<your-account-identifier>"
gh variable set SNOWFLAKE_WAREHOUSE --body "CINDER_DEMO_WH"
gh variable set SNOWFLAKE_CI_USER   --body "CINDER_CI_SVC"
gh variable set SNOWFLAKE_CI_ROLE   --body "CINDER_DBT_CI_ROLE"
gh variable set SNOWFLAKE_PROD_USER --body "CINDER_DEPLOY_SVC"
gh variable set SNOWFLAKE_PROD_ROLE --body "CINDER_DBT_PROD_ROLE"

gh secret set SNOWFLAKE_PRIVATE_KEY < ~/.snowflake-keys/ci_key_pkcs8.pem
```

Set `SNOWFLAKE_EAI` too if you renamed the external access integration.

**4. Create the `production` environment**, which `deploy.yml` declares so merges can be gated
on a review:

```bash
gh api -X PUT repos/<owner>/<repo>/environments/production
```

Open a pull request and CI runs.

### Network access — the step that blocks most accounts

Most real accounts restrict access by IP. CI runners are ephemeral and their addresses are
neither stable nor yours, so every pipeline fails with:

```
Incoming request with IP/Token x.x.x.x is not allowed to access Snowflake
```

**Do not widen your account-level network policy.** It usually protects every human and service
in the account, and adding thousands of public cloud ranges removes that protection for
everyone to unblock one pipeline.

Snowflake maintains the address lists for you. `SNOWFLAKE.NETWORK_SECURITY` holds managed
network rules for common CI and BI platforms, kept current as the providers change:

```sql
SHOW NETWORK RULES IN SCHEMA SNOWFLAKE.NETWORK_SECURITY;
```

`setup/04_ci_access.sql` builds a policy from `GITHUBACTIONS_GLOBAL` and attaches it **to the
two service users only**. A user-level policy overrides the account-level one for that user
alone, so humans keep whatever restriction the account imposes and the account policy is never
touched. Substitute a different managed rule for Azure DevOps, dbt Cloud or another platform.

Be clear-eyed about the trade: this admits any GitHub Actions runner, not only yours, so the key
is what actually authenticates. Guard the secret, keep the roles narrow, and prefer workload
identity federation — `deploy-oidc.yml.example` — for anything long-lived.

### What CI cannot do here

State-based selection. `--state`, `--select state:modified` and defer-to-production are not
available on Snowflake-native dbt today, so every PR builds the whole project. At this size
that is seconds. If a project outgrows it, the answer is to split the project rather than to
approximate state comparison.

---

## Pointing it at real data

The project reads seeds by default. Switch to the real landing tables per event, because in
practice some events are already being ingested while others are not yet routed:

```bash
# Note the argument order: the CLI's own options come BEFORE the project name. Anything after
# the `build` subcommand is forwarded verbatim to dbt.

# Everything from the landing tables
snow dbt execute --database CINDER_ANALYTICS --schema DBT \
  CINDER_WEBHOOKS build \
  --vars '{"cinder_source_mode": "raw"}'

# One event live, the other still on seeds
snow dbt execute --database CINDER_ANALYTICS --schema DBT \
  CINDER_WEBHOOKS build \
  --vars '{"cinder_source_mode_by_event": {"job_actioned": "raw", "job_closed": "seed"}}'
```

If a landing table does not exist yet, that branch is dropped with a log message instead of
failing. A project that will not compile because a table is missing blocks the ingestion team's
work, which is the opposite of helpful.

Point at a different landing zone with `raw_database` and `raw_schema`.

### One thing to fill in

`seeds/cinder/seed_cinder_policy_areas.csv` maps a parent policy id to its name. This cannot be
derived from the webhooks: payloads carry a policy's `parent_id` but never the parent's *name*,
and parents are grouping nodes rather than things reviewers pick, so they are rarely applied
directly.

Without it, policy distribution can only be reported at leaf level, where it fragments into
unreadably thin slices. Populate it from Cinder's policies API, which does expose the full
tree. Any id absent from it degrades gracefully — the policy falls back to its own name and
`policy_parent_name_resolved` reports false, so the gap stays visible.

---

## Repository layout

```
setup/                  Snowflake objects. Run in order; all idempotent.
  01_account_setup.sql     databases, schemas, warehouse, EAI, roles
  02_raw_tables.sql        landing tables matching the ingestion output shape
  03_governance.sql        PII tag, masking policies, classification profile
  04_ci_access.sql         CI service users, keypair auth, runner network access
  --- deploy and build here: the files below attach to tables dbt creates ---
  05_apply_column_tags.sql reapply PII tags — MUST run after every rebuild
  06_operations.sql        data metric functions, scheduled task, alerts
  99_teardown.sql          drop everything, including the service users

seeds/
  generate_seeds.py        deterministic generator; the CSVs are committed
  cinder/                  synthetic payloads + the policy-area lookup

models/
  sources/                 source declarations and freshness thresholds
  staging/base/            seeds-or-raw resolution and deduplication
  staging/                 one model per event grain
  marts/                   dimensions and facts
  semantic/                the semantic view

macros/                  source switching, dedup key, schema naming
tests/                   business invariants a generic test cannot express
scripts/                 the private-reference guard used by pre-commit
.github/workflows/       CI and deployment
.github/ci-profiles/     credential-free profile, so `dbt parse` needs no connection
.sqlfluff-stubs/         stub ref()/source()/config(), so linting needs no warehouse
requirements-validate.txt  lint and parse toolchain  (kept apart: dbt-snowflake and
requirements-deploy.txt    deploy toolchain           snowflake-cli conflict on pip)
```

The last four are worth knowing about because they are not obvious and the rest of the setup
depends on them. Both `dbt parse` and `sqlfluff` are made to run with **no Snowflake
credentials at all** — that is what lets CI reject a broken project in seconds without
touching a warehouse, and it is why linting is not gated behind a working connection.

## Adapting this to your own environment

Object names are generic and every one is overridable. In rough order of what you will change:

1. **`dim_enforcement_action`** — the severity ladder is a local convention, not something
   Cinder supplies. Replace it with yours. Unrecognised actions fall to `unclassified` rather
   than being guessed into a bucket, so a new action shows up rather than landing in the wrong
   place.
2. **`dim_reviewer`** — vendor segmentation is parsed from group names by convention
   (`<Vendor> BPO Moderator - <Specialism>`). Adjust to your naming. It fails safe: an
   unmatched name leaves the vendor null.
3. **`seed_cinder_policy_areas.csv`** — your policy tree.
4. **Object names** — change them in `setup/01` and pass matching `raw_database` / `raw_schema`
   vars.
5. **Alert recipients** — `setup/04` has a placeholder email address.
6. **`scripts/check_no_private_references.sh`** — add patterns specific to your environment
   before sharing a fork.

## Conventions

- No `env_var()` anywhere. Snowflake-native dbt does not support it and a project using it
  fails to deploy. Everything configurable is a `var` with a plain-string default.
- `profiles.yml` lives in the project directory and carries no credentials. Inside Snowflake,
  authentication is the session's.
- No local packages. Cross-folder `local:` dependencies are unsupported; shared macros must be
  vendored in.
- Comments explain *why*, not *what*. If a model does something surprising, the reason is next
  to it.

## License

MIT. See [LICENSE](LICENSE).

All data in this repository is synthetic. The Cinder event shapes are modelled from public
documentation and observed payload structure; no real moderation content, accounts or personal
data are included.
