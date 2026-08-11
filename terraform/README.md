# Terraform — Snowsight Workspaces Git integration

The Terraform equivalent of [`setup/07_workspaces_git.sql`](../setup/07_workspaces_git.sql).

**Apply one or the other, not both.** Both create the same two objects. If you run the SQL
first and then `terraform apply`, Terraform tries to create an integration that already
exists and fails. To adopt an existing one instead, see [Adopting objects](#adopting-objects-created-by-the-sql).

## What it manages

| Object | Resource |
|---|---|
| `GITHUB_APP_INTEGRATION` | `snowflake_api_integration_git_repository_github_app` |
| `USAGE` on it, per role | `snowflake_grant_privileges_to_account_role` |

That is the whole footprint. Everything else in this project — databases, roles, masking
policies, the dbt project object — stays in `setup/*.sql`, because that SQL is also the
teaching material and duplicating it would guarantee the two drift.

## What Terraform cannot do

Authorising the Snowflake GitHub App is an **OAuth consent flow in a browser**. Terraform
creates the integration; a human authorises it once per GitHub account. After `apply`:

1. Snowsight » Projects » Workspaces » **From Git repository**
2. Repository URL: the HTTPS clone URL
3. API integration: select `GITHUB_APP_INTEGRATION`
4. **Sign in** » **Configure** » **Authorize** Snowflake Computing
5. Permissions: **Read access to metadata** and **Read and write access to code** — write is
   what enables commit and push
6. Repository access: prefer **Only select repositories**

`terraform output next_step` prints this.

## Running it

Credentials come from the environment. There is no `terraform.tfvars` holding secrets and no
credential in any `.tf` file:

```bash
export SNOWFLAKE_ORGANIZATION_NAME="<your-org>"        # SELECT CURRENT_ORGANIZATION_NAME()
export SNOWFLAKE_ACCOUNT_NAME="<your-account>"         # SELECT CURRENT_ACCOUNT_NAME()
export SNOWFLAKE_USER="<your-user>"
export SNOWFLAKE_AUTHENTICATOR="SNOWFLAKE_JWT"
export SNOWFLAKE_PRIVATE_KEY="$(cat ~/.snowflake/rsa_key_pkcs8.pem)"

cp terraform.tfvars.example terraform.tfvars   # then set api_allowed_prefixes
terraform init
terraform plan
terraform apply
```

### Four things that will waste your afternoon

Each of these produces an error that points somewhere other than the cause. All four were
hit getting this to plan cleanly.

**1. The provider ignores your CLI connection.** The obvious move is to reuse
`~/.snowflake/connections.toml` via the `profile` argument. It does not work well:

- the provider does not honour the CLI's `default_connection_name`, so it looks for a
  profile literally named `default` and reports `260000: account is empty`
- its default config path is the legacy `~/.snowflake/config`, which a modern CLI never
  creates — `stat ~/.snowflake/config: no such file or directory`
- pointed at `connections.toml` via `SNOWFLAKE_CONFIG_PATH`, it rejects keys its own config
  struct does not model — `toml: cannot decode TOML string into a Go value of type
  sdk.ConfigDTO`

Environment variables avoid all three, and are what CI needs anyway since a runner has no
TOML file.

**2. `SNOWFLAKE_ACCOUNT` is no longer the way in.** The account *locator* now requires an
opt-in experiment:

```
the account field requires the "PROVIDER_CONFIGURATION_ACCOUNT_FALLBACK" experiment
```

Use `SNOWFLAKE_ORGANIZATION_NAME` and `SNOWFLAKE_ACCOUNT_NAME` instead.

**3. `SNOWFLAKE_PRIVATE_KEY` takes the key itself, not a path.** There is no
`private_key_path`. Setting a path yields `trying to use keypair authentication, but
PrivateKey was not provided`, which sounds like nothing was set at all. Use
`"$(cat <path>)"`.

**4. The resource is a preview feature.** It must be named in `preview_features_enabled`
(see `providers.tf`), and the value is the *feature* name — the resource name plus
`_resource` — not the resource name. Because it is preview, breaking changes can arrive
without a major version bump, which is why `versions.tf` pins a minor line.

## Adopting objects created by the SQL

If you already ran `setup/07_workspaces_git.sql` and now want Terraform to own the result,
import rather than recreate:

```bash
terraform import \
  'snowflake_api_integration_git_repository_github_app.workspaces' \
  '"GITHUB_APP_INTEGRATION"'

terraform import \
  'snowflake_grant_privileges_to_account_role.workspaces_usage["SYSADMIN"]' \
  'SYSADMIN|false|false|USAGE|ON_ACCOUNT_OBJECT|INTEGRATION|GITHUB_APP_INTEGRATION'
```

Note the inner double quotes on the integration name — the provider's import ID format
requires them. Run `terraform plan` afterwards and expect no changes; a diff means your
variables do not match what the SQL created.

## State

Local, which is fine for a demo and wrong for anything shared: it cannot be locked, cannot
be recovered, and a second person running `apply` will create duplicates. `versions.tf` has
a commented S3 backend block — the DynamoDB lock table is the part that matters.

`terraform.tfvars` is gitignored. It holds no secrets, but it does hold your GitHub org
name, and this repository is meant to be shareable.
