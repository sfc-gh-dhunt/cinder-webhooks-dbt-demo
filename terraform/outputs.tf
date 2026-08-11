output "integration_name" {
  description = "Select this in Snowsight » Workspaces » From Git repository » API integration."
  value       = snowflake_api_integration_git_repository_github_app.workspaces.name
}

output "user_auth_type" {
  description = <<-EOT
    Should be SNOWFLAKE_GITHUB_APP. This is what makes the "Sign in" option appear in the
    Workspaces dialog — if it is empty, the dialog will only ever offer "Personal access
    token" and "Public repository".
  EOT
  value       = try(snowflake_api_integration_git_repository_github_app.workspaces.describe_output[0].user_auth_type, null)
}

output "next_step" {
  description = "The part Terraform cannot do."
  value       = "Authorize the app in a browser: Snowsight » Projects » Workspaces » From Git repository » select ${snowflake_api_integration_git_repository_github_app.workspaces.name} » Sign in » Authorize. Grant Contents: Read and write, and select the specific repository. See README.md."
}
