# =====================================================================================
# Cinder webhooks dbt demo
# =====================================================================================
# Every command you need, with the arguments already correct. The point is that nobody has to
# remember that `snow dbt execute` needs the database and schema restated on every
# invocation, or that local dbt artifacts have to be removed before a deploy.
#
#   make help          list targets
#   make setup         create all Snowflake objects
#   make build         build and test locally
#   make deploy        deploy the project object to Snowflake
#   make check         everything CI would check, before you push
#
# Override any variable inline:  make build SNOW_CONNECTION=my_conn
# =====================================================================================

.DEFAULT_GOAL := help
SHELL := /bin/bash

# ---- Configuration ------------------------------------------------------------------
SNOW_CONNECTION ?= default
DATABASE        ?= CINDER_ANALYTICS
DBT_SCHEMA      ?= DBT
PROJECT_NAME    ?= CINDER_WEBHOOKS
EAI             ?= CINDER_DEMO_DBT_EAI
ROLE            ?= CINDER_DBT_PROD_ROLE

# Local development reads a profile from outside the repository, so no credentials ever sit
# in a tracked file. `make dev-profile` writes it for you.
DEV_PROFILES_DIR ?= $(HOME)/.dbt/cinder-webhooks

SNOW      := snow --connection $(SNOW_CONNECTION)
DBT       := DBT_PROFILES_DIR=$(DEV_PROFILES_DIR) dbt
DBT_FLAGS := --database $(DATABASE) --schema $(DBT_SCHEMA) --role $(ROLE)

.PHONY: help
help:
	@echo "Cinder webhooks dbt demo"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-22s\033[0m %s\n", $$1, $$2}'
	@echo

# =====================================================================================
# Snowflake setup
# =====================================================================================

.PHONY: setup
setup: setup-account setup-raw setup-governance setup-operations ## Create every Snowflake object (run once)
	@echo "Setup complete."

.PHONY: setup-account
setup-account: ## Databases, schemas, warehouse, external access integration, roles
	$(SNOW) sql -f setup/01_account_setup.sql

.PHONY: setup-raw
setup-raw: ## Landing tables matching the ingestion layer's output shape
	$(SNOW) sql -f setup/02_raw_tables.sql

.PHONY: setup-governance
setup-governance: ## PII tag, masking policies, classification profile
	$(SNOW) sql -f setup/03_governance.sql

.PHONY: setup-operations
setup-operations: ## Data metric functions, scheduled task, alerts
	$(SNOW) sql -f setup/04_operations.sql

.PHONY: teardown
teardown: ## Drop everything this project created (destructive — asks first)
	@echo "This drops CINDER_RAW, CINDER_ANALYTICS, the warehouse, the roles and the integrations."
	@read -p "Type the word 'destroy' to continue: " confirm && [ "$$confirm" = "destroy" ]
	$(SNOW) sql -f setup/99_teardown.sql

# =====================================================================================
# Local development
# =====================================================================================

.PHONY: dev-profile
dev-profile: ## Write a local dbt profile outside the repo (prompts for your connection)
	@mkdir -p $(DEV_PROFILES_DIR)
	@echo "Writing $(DEV_PROFILES_DIR)/profiles.yml"
	@echo "This file lives OUTSIDE the repository so credentials cannot be committed."
	@read -p "Snowflake account: " acct; \
	 read -p "User: " user; \
	 read -p "Private key path: " keypath; \
	 read -p "Role [$(ROLE)]: " role; role=$${role:-$(ROLE)}; \
	 printf 'cinder_webhooks:\n  target: dev\n  outputs:\n    dev:\n      type: snowflake\n      account: %s\n      user: %s\n      private_key_path: %s\n      role: %s\n      database: %s\n      schema: PUBLIC\n      warehouse: CINDER_DEMO_WH\n      threads: 8\n' \
	   "$$acct" "$$user" "$$keypath" "$$role" "$(DATABASE)" > $(DEV_PROFILES_DIR)/profiles.yml
	@chmod 600 $(DEV_PROFILES_DIR)/profiles.yml
	@echo "Done."

.PHONY: deps
deps: ## Install dbt package dependencies locally
	$(DBT) deps

.PHONY: seeds
seeds: ## Regenerate the synthetic seed files
	python3 seeds/generate_seeds.py

.PHONY: build
build: ## Build and test everything locally
	$(DBT) build

.PHONY: rebuild
rebuild: ## Full refresh. Required after changing incremental logic
	$(DBT) build --full-refresh

.PHONY: test
test: ## Run tests only
	$(DBT) test

.PHONY: docs
docs: ## Generate and serve the dbt documentation site
	$(DBT) docs generate && $(DBT) docs serve

.PHONY: clean
clean: ## Remove local dbt artifacts
	rm -rf target dbt_packages logs package-lock.yml

# =====================================================================================
# Deployment
# =====================================================================================

.PHONY: deploy
deploy: clean ## Deploy the project object to Snowflake (creates a new version)
	@# `clean` first, and not as a nicety. dbt_packages/ and package-lock.yml must not be
	@# uploaded: Snowflake resolves packages itself, and a lock file written by a newer local
	@# dbt is rejected with a misleading "packages.yml is malformed" error.
	$(SNOW) dbt deploy $(PROJECT_NAME) \
		--source . \
		--database $(DATABASE) \
		--schema $(DBT_SCHEMA) \
		--role $(ROLE) \
		--external-access-integration $(EAI)

.PHONY: deploy-run
deploy-run: deploy ## Deploy, run in Snowflake, then reapply column tags
	$(SNOW) dbt execute $(DBT_FLAGS) $(PROJECT_NAME) build
	@# A dbt rebuild uses CREATE OR REPLACE, which drops column tags — and the masking
	@# policies are attached BY tag. An untagged column is an unmasked column, so this is not
	@# optional housekeeping.
	$(MAKE) setup-governance

.PHONY: run-remote
run-remote: ## Run the deployed project inside Snowflake
	$(SNOW) dbt execute $(DBT_FLAGS) $(PROJECT_NAME) build

.PHONY: versions
versions: ## Show deployed versions of the project object
	$(SNOW) sql -q "SHOW VERSIONS IN DBT PROJECT $(DATABASE).$(DBT_SCHEMA).$(PROJECT_NAME);"

# =====================================================================================
# Verification
# =====================================================================================

.PHONY: check
check: seeds-match parse lint ## Everything CI checks, before you push
	@echo "All checks passed."

.PHONY: lint
lint: ## Lint the SQL (needs `make deps` and a working dev profile)
	@# sqlfluff's dbt templater compiles the project to resolve ref() and source(), and
	@# compilation connects to Snowflake. So linting needs credentials — which is why it is
	@# not part of the credential-free `parse` target, and why CI runs it after connecting.
	DBT_PROFILES_DIR=$(DEV_PROFILES_DIR) sqlfluff lint models tests --disable-progress-bar

.PHONY: fix
fix: ## Auto-fix what sqlfluff can
	DBT_PROFILES_DIR=$(DEV_PROFILES_DIR) sqlfluff fix models tests --disable-progress-bar

.PHONY: parse
parse: ## Validate project structure without connecting to Snowflake
	DBT_PROFILES_DIR=.github/ci-profiles dbt parse --no-partial-parse

.PHONY: seeds-match
seeds-match: ## Assert the committed seeds match their generator
	@python3 seeds/generate_seeds.py >/dev/null
	@if ! git diff --quiet --exit-code seeds/cinder/; then \
		echo "Seed files differ from generator output. Commit the regenerated files."; \
		git diff --stat seeds/cinder/; \
		exit 1; \
	fi
	@echo "Seeds match the generator."

.PHONY: verify-semantic-view
verify-semantic-view: ## Prove the semantic view answers a question, not just that it built
	@# A semantic view can build successfully and return nothing — a valid definition over a
	@# broken relationship is still valid DDL. Querying it is the only real check.
	$(SNOW) sql -q "SELECT * FROM SEMANTIC_VIEW( \
		$(DATABASE).SEMANTIC.SEM_CINDER_MODERATION \
		DIMENSIONS queues.queue_name \
		METRICS decisions.median_handle_time_hours, decisions.total_decisions \
	) ORDER BY median_handle_time_hours DESC;"

.PHONY: verify-masking
verify-masking: ## Show masked output, as an unprivileged role
	@# USE SECONDARY ROLES NONE is essential here. Snowflake activates all of a user's granted
	@# roles as secondary roles by default, and IS_ROLE_IN_SESSION is satisfied by any of them
	@# — so without this you see plaintext and conclude the masking is broken.
	$(SNOW) sql --role CINDER_ANALYST_NO_PII -q "USE SECONDARY ROLES NONE; \
		USE WAREHOUSE CINDER_DEMO_WH; \
		SELECT reviewer_email, reviewer_name, staffing_model \
		FROM $(DATABASE).MARTS.DIM_REVIEWER ORDER BY reviewer_email LIMIT 5;"
