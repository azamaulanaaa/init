SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help ci check-bash check-mise hooks

help: ## Show this help.
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

ci: ## Run every check.
	scripts/ci.sh

check-bash: ## Check every bash file with shellcheck.
	scripts/check-bash.sh

check-mise: ## Check the mise config file when mise is available.
	scripts/check-mise.sh

hooks: ## Install the git hooks in .githook.
	git config core.hooksPath .githook
	chmod +x .githook/pre-commit .githook/pre-push
