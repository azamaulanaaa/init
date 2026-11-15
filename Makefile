SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help ci check-jactionlint check-bash check-commits check-hadolint check-markdown check-mise check-shfmt check-zizmor hooks release

help: ## Show this help.
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

ci: ## Run every check.
	scripts/ci.sh

check-jactionlint: ## Check the GitHub Actions workflows with jactionlint.
	scripts/check-jactionlint.sh

check-bash: ## Check every bash file with shellcheck.
	scripts/check-bash.sh

check-commits: ## Check the commit history with cocogitto.
	scripts/check-commits.sh

check-hadolint: ## Check the Dockerfile and Containerfile files with hadolint.
	scripts/check-hadolint.sh

check-markdown: ## Check every Markdown file with markdownlint-cli2.
	scripts/check-markdown.sh

check-mise: ## Check the mise config file when mise is available.
	scripts/check-mise.sh

check-shfmt: ## Check the bash file format with shfmt.
	scripts/check-shfmt.sh

check-zizmor: ## Check the GitHub Actions workflows with zizmor.
	scripts/check-zizmor.sh

hooks: ## Install the git hooks in .githook.
	git config core.hooksPath .githook
	chmod +x .githook/commit-msg .githook/pre-commit .githook/pre-push

release: ## Bump the version and update the changelog.
	cog bump --auto
