variable "snowflake_profile" {
  description = <<-EOT
    Connection name in ~/.snowflake/connections.toml.

    MUST BE SET EXPLICITLY. The provider does NOT honour the Snowflake CLI's
    default_connection_name from config.toml — it looks for a profile literally named
    "default". If you have no such section, plan fails with:

        Error: 260000: account is empty

    which reads like a missing account variable rather than an unresolved profile. Pass
    the connection name you use with `snow --connection <name>`.
  EOT
  type        = string
  default     = "default"
}

variable "snowflake_config_file_path" {
  description = <<-EOT
    Path to the TOML holding your connection profiles. Defaults to the file the modern
    Snowflake CLI writes, not the provider's older ~/.snowflake/config default.
  EOT
  type        = string
  default     = "~/.snowflake/connections.toml"
}

variable "snowflake_role" {
  description = "Role Terraform uses. Needs CREATE API INTEGRATION, which is usually admin-only."
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "integration_name" {
  description = "Name of the API integration. Must be unique in the account."
  type        = string
  default     = "GITHUB_APP_INTEGRATION"
}

variable "api_allowed_prefixes" {
  description = <<-EOT
    GitHub namespaces this integration may reach, e.g. ["https://github.com/my-org"].

    Deliberately has NO DEFAULT. A default here would be the one value guaranteed to be
    wrong in someone else's account, and getting it wrong fails at clone time with an
    error that points at GitHub rather than at this list. Set it explicitly.
  EOT
  type        = list(string)

  validation {
    # Catches the two mistakes that produce confusing downstream failures: an SSH or bare
    # URL the integration can never match, and the wide-open prefix that authorises all of
    # GitHub for anyone holding USAGE.
    condition = alltrue([
      for p in var.api_allowed_prefixes :
      startswith(p, "https://") && length(trimspace(replace(p, "https://github.com/", ""))) > 0
    ])
    error_message = "Each prefix must start with https:// and name an org or user — not a bare 'https://github.com/', which would authorise every repository on GitHub."
  }
}

variable "usage_roles" {
  description = <<-EOT
    Roles granted USAGE, i.e. the roles that can see this integration in the Workspaces
    dialog. The owning role (ACCOUNTADMIN by default) already has it implicitly.
  EOT
  type        = list(string)
  default     = ["SYSADMIN"]
}
