terraform {
  required_version = ">= 1.4.0"

  required_providers {
    snowflake = {
      source = "snowflakedb/snowflake"
      # Pinned to a minor line. The GitHub App resource used here is a PREVIEW feature of
      # the provider, which means breaking changes are expected without a major version
      # bump — so a loose constraint like ">= 2.0" will eventually break a plan that used
      # to work. Bump this deliberately after reading the changelog.
      version = "~> 2.19"
    }
  }

  # LOCAL STATE, which is fine for a demo and wrong for anything shared. State records
  # what Terraform believes exists; on a laptop it cannot be locked, cannot be recovered,
  # and a second person running apply will happily create duplicates. Before more than one
  # person touches this, move it to a backend:
  #
  # backend "s3" {
  #   bucket         = "your-tf-state-bucket"
  #   key            = "snowflake/workspaces-git/terraform.tfstate"
  #   region         = "eu-west-2"
  #   dynamodb_table = "your-tf-lock-table"   # the lock is the point
  #   encrypt        = true
  # }
}
