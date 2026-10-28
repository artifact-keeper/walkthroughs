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

lab-up: ## (re)start the lab upstream (a PyPI index and npm registry with publish times we control)
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

lock: ## re-resolve app/uv.lock, app/package-lock.json, internal/build-constraints.txt through the registry (review the diff!)
	rm -f app/uv.lock app/package-lock.json
	sandbox/run.sh -- sh -c 'uv lock && npm install --package-lock-only --ignore-scripts'
	sandbox/run.sh -w internal -- uv pip compile -q --universal --generate-hashes -p 3.12 build-requirements.in -o build-constraints.txt

curation: ## approved list: the names in the reviewed lockfiles, everything else blocked
	policies/curation.sh

install: ## uv sync --locked and npm ci in the sandbox, then run the app
	@log=$$(mktemp); trap 'rm -f "$$log"' EXIT; \
	echo "sandbox/run.sh -- sh -c 'uv sync --locked && npm ci --ignore-scripts && .venv/bin/python main.py'"; \
	if ! sandbox/run.sh -- sh -c 'uv sync --locked && npm ci --ignore-scripts && .venv/bin/python main.py' 2>&1 | tee "$$log"; then \
	  if grep -qE 'scan_blocked|403 Forbidden|E403' "$$log"; then \
	    echo "install: a locked version was refused (403; gates/probe.sh shows why, e.g. scan_blocked: a new advisory):" \
	         "re-lock with make lock or add an exception (policies/exceptions.txt)" >&2; fi; \
	  exit 1; fi

agent: ## replay the scripted agent session (agent/plan.toml); transcripts in agent/out/
	agent/agent.sh

gates: ## restart the lab upstream, run G1-G11 (PASS / FAIL / BLOCKED per gate), results in out/gates/
	gates/run-all.sh

reproduce: ## G10, WIPES THE STACK: make clean all gates; make all gates; make clean all gates (out/reproduce.txt)
	gates/reproduce.sh

all: registry-up lab-up bootstrap policies exceptions sandbox internal curation install agent ## everything, from an empty registry

clean: ## delete the stack and all state: containers, volumes, networks, tokens, sandbox and proxied base images
	registry/clean.sh

screens-ready: ## print the UI URL and where the admin credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30445}  (certificate from the stack's internal CA)"
	@echo "Login:     admin / ADMIN_PASSWORD in registry/.env"
