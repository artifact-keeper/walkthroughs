# A private marketplace of AI coding-agent plugins on Artifact Keeper (agentplugins format).
# Pipeline: registry-up -> bootstrap -> client -> validate -> publish -> indexes
#           -> consume-claude -> consume-cli -> update -> scan -> audit   (then: make gates)
# Every target is re-runnable. No sudo; rootless podman only. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

.PHONY: help registry-up registry-down bootstrap client validate publish indexes consume-claude \
        consume-cli update scan audit gates screens-ready all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'

registry-up: ## start the ak-agents stack (generates .env and secrets, exports the CA)
	registry/up.sh

registry-down: ## stop the stack (volumes kept; registry/down.sh --volumes wipes)
	registry/down.sh

bootstrap: ## repositories, scan policy, developer user, tokens, CA in `trust` (idempotent)
	registry/bootstrap.sh

client: ## build the workstation image: Claude Code, Codex, Copilot, Cursor CLI, ak, the CA
	client/build.sh

validate: ## claude plugin validate on the three plugins (and the Standard manifest's rules)
	flows/validate.sh

publish: ## publish the plugins with ak (CI token) and one with plain curl -T; wait for scans
	flows/publish.sh

indexes: ## fetch and pretty-print the five marketplace documents and <name>/index.json
	flows/indexes.sh

consume-claude: ## Claude Code: settings route, token-in-path route, public repository
	flows/consume-claude.sh

consume-cli: ## ak agent plugins install for cursor, codex and vscode; the agents' own listings
	flows/consume-cli.sh

update: ## publish acme-review 1.1.0; Claude Code update; ak list --check-updates, update --all
	flows/update.sh

scan: ## scan results of a published zip; block_unscanned holding a version until its scan
	flows/scan.sh

audit: ## download statistics and audit events for a publish and an install (REST API)
	flows/audit.sh

gates: ## run G1-G10 (PASS / FAIL / BLOCKED per check), results in out/gates/
	gates/run-all.sh

screens-ready: ## print the UI URL and where the credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30447}  (certificate from the stack's internal CA)"
	@echo "CA:        $(CURDIR)/registry/out/ak-internal-ca.crt"
	@echo "Admin:     user admin, password = ADMIN_PASSWORD in $(CURDIR)/registry/.env"
	@echo "Developer: user developer, password in $(CURDIR)/registry/.tokens/developer.password"
	@echo "Agent Plugins setup tab: Repositories > agent-plugins > Set up"

all: registry-up bootstrap client validate publish indexes consume-claude consume-cli update scan audit ## everything except the gates, from an empty registry
	@echo "all: done. Next: make gates"

clean: ## remove the stack, its volumes and network, the workstation image and all local state
	registry/clean.sh
