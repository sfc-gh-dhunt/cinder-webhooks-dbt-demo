# =====================================================================================
# Snowsight Workspaces — Git integration
# =====================================================================================
# The Terraform equivalent of setup/07_workspaces_git.sql. Apply EITHER this OR the SQL,
# not both: they create the same objects, so running one after the other leaves the second
# reporting an object it does not own. If you apply Terraform, Terraform owns it.
#
# WHAT TERRAFORM CANNOT DO HERE, and it is the step that actually matters: authorising the
# Snowflake GitHub App is an OAuth consent flow in a browser. Terraform creates the
# integration; a human still clicks Authorize once per GitHub account. See README.md.

# -------------------------------------------------------------------------------------
# The API integration
# -------------------------------------------------------------------------------------
# Uses the dedicated GitHub App resource rather than the generic `snowflake_api_integration`
# — that one explicitly does not support the git_https_api provider, and is deprecated in
# favour of these per-purpose resources. There are siblings for the other auth strategies:
# _git_repository_token (PAT), _git_repository_oauth2 (your own OAuth app, needed for
# GitHub Enterprise Server and *.ghe.com), and _git_repository_private_link.
resource "snowflake_api_integration_git_repository_github_app" "workspaces" {
  name = var.integration_name

  # SCOPED TO ONE NAMESPACE ON PURPOSE. "https://github.com/" would authorise every
  # repository on GitHub for any role holding USAGE on this integration. Keep this as tight
  # as the work allows and widen it deliberately.
  api_allowed_prefixes = var.api_allowed_prefixes

  enabled = true
  comment = "OAuth2 via the Snowflake GitHub App for Snowsight Workspaces. No stored token. Managed by Terraform."
}

# -------------------------------------------------------------------------------------
# Who can use it
# -------------------------------------------------------------------------------------
# Without USAGE the integration is simply absent from the Workspaces dialog, with no
# explanation offered — the single most common reason this setup looks broken.
#
# `snowflake_grant_privileges_to_account_role` rather than a bare grant resource: it is the
# current, non-deprecated form, and it handles the drift case where someone grants or
# revokes the same privilege by hand.
resource "snowflake_grant_privileges_to_account_role" "workspaces_usage" {
  for_each = toset(var.usage_roles)

  account_role_name = each.value
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_api_integration_git_repository_github_app.workspaces.name
  }
}
