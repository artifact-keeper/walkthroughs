# An AI coding agent that can only install what the registry allows, on Artifact Keeper 1.11.7.
# Pipeline: registry-up -> lab-up -> bootstrap -> policies -> exceptions -> sandbox -> internal -> curation
#           -> install -> agent -> gates
# Every target is re-runnable. No sudo; rootless podman only. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

.PHONY: help registry-up registry-down lab-up lab-down bootstrap policies exceptions sandbox internal lock curation \
        install agent gates reproduce all clean screens-ready

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

registry-up: ## start the ak-agent stack (generates .env and secrets, exports the CA)
	registry/up.sh

registry-down: ## stop the stack (volumes kept)
	registry/down.sh

lab-up: ## (re)start the lab upstream (fresh releases become fresh again)
	lab-upstream/up.sh

lab-down: ## stop the lab upstream
	lab-upstream/down.sh

bootstrap: ## repositories, upstream filter, users, tokens, podman auth, CA in `trust` (idempotent)
	registry/bootstrap.sh

policies: ## age gate (7 days) and scan-on-proxy (fail closed, high) on the public-facing repos
	policies/apply.sh

exceptions: ## approve the reviewed cooldown exceptions in policies/exceptions.txt (security fixes)
	policies/exceptions.sh

sandbox: ## build the agent sandbox image (uv + npm, registry-only config, internal CA)
	sandbox/build.sh

internal: ## build and publish acme-agent-tools and @acme/tickets-mcp, as CI would
	internal/publish.sh

lock: ## re-resolve app/uv.lock and app/package-lock.json through the registry (review the diff!)
	rm -f app/uv.lock app/package-lock.json
	sandbox/run.sh -- sh -c 'uv lock && npm install --package-lock-only --ignore-scripts'

curation: ## approved list: the names in the reviewed lockfiles, everything else blocked
	policies/curation.sh

install: ## uv sync --locked and npm ci in the sandbox, then run the app
	sandbox/run.sh -- sh -c 'uv sync --locked && npm ci --ignore-scripts && .venv/bin/python main.py'

agent: ## replay the scripted agent session (agent/plan.yaml); transcripts in agent/out/
	agent/agent.sh

gates: ## run G1-G10 (PASS / FAIL / BLOCKED per gate), results in out/gates/
	gates/run-all.sh

reproduce: ## G10: make clean all gates twice from an empty registry (out/reproduce.txt)
	gates/reproduce.sh

all: registry-up lab-up bootstrap policies exceptions sandbox internal curation install agent ## everything, from an empty registry

clean: ## stop everything and delete all state (volumes, tokens, venvs, sandbox image)
	-lab-upstream/down.sh
	-registry/down.sh --volumes
	-podman volume ls -q --filter name=ak-agent_ | xargs -r podman volume rm -f >/dev/null
	-podman network rm -f agent-net ak-agent-net >/dev/null 2>&1
	rm -rf registry/.env registry/.tokens registry/out out/gates agent/out app/.venv app/node_modules internal/acme-agent-tools/dist
	-podman rmi -f localhost/ak-agent/sandbox:1 >/dev/null 2>&1

screens-ready: ## print the UI URL and where the admin credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30445}  (certificate from the stack's internal CA)"
	@echo "Login:     admin / ADMIN_PASSWORD in registry/.env"
