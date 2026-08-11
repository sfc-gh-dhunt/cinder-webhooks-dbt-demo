# =====================================================================================
# Provider
# =====================================================================================
# NO CREDENTIALS IN THIS FILE, and none in any .tf file. The provider takes them from the
# environment:
#
#   export SNOWFLAKE_ACCOUNT="<your-account-identifier>"
#   export SNOWFLAKE_USER="<your-user>"
#   export SNOWFLAKE_AUTHENTICATOR="SNOWFLAKE_JWT"
#   export SNOWFLAKE_PRIVATE_KEY_PATH="$HOME/.snowflake/rsa_key_pkcs8.pem"
#
# ENVIRONMENT VARIABLES RATHER THAN THE CLI's connections.toml, which is the obvious thing
# to reach for and does not work cleanly. The provider ignores the CLI's
# default_connection_name, defaults to the legacy ~/.snowflake/config path that a modern
# CLI never creates, and — if pointed at connections.toml via SNOWFLAKE_CONFIG_PATH —
# rejects files containing keys its own config struct does not model:
#
#   toml: cannot decode TOML string into a Go value of type sdk.ConfigDTO
#
# Environment variables sidestep all three, and are what CI would use in any case, since a
# runner has no connections.toml. If you would rather use a profile, the `profile` argument
# still exists — expect to trim your TOML to the keys the provider accepts.
provider "snowflake" {
  role = var.snowflake_role

  # PREVIEW FEATURES MUST BE OPTED INTO EXPLICITLY. The GitHub App integration resource is
  # preview, and without naming it here Terraform fails at plan time with an error saying
  # the resource is not enabled — which reads like a version problem rather than a missing
  # opt-in. The provider requires the feature name, not the resource name.
  preview_features_enabled = [
    "snowflake_api_integration_git_repository_github_app_resource",
  ]
}

# EXPECTED WARNING, not a misconfiguration. The provider emits
# "Argument is deprecated ... Skipping TOML configuration file permission verification"
# about its OWN default, so it appears whether or not you set the field — and setting it
# explicitly only moves the warning onto your line. The underlying advice is worth acting
# on regardless:
#
#   chmod 600 ~/.snowflake/connections.toml
#
# A future major version will enforce that, and a file with looser permissions will fail
# rather than warn.
