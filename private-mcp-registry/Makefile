# A private MCP registry on Artifact Keeper (mcp repository type, artifact-keeper#5257).
# Pipeline: registry-up -> bootstrap -> client -> publish -> clients -> curate
#           -> supply-chain -> ci -> virtual -> bundles   (then: make gates)
# No sudo; rootless podman only. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

.PHONY: help registry-up registry-down bootstrap client publish clients curate supply-chain ci \
        virtual bundles gates screens screens-ready all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

registry-up: ## start the ak-mcp stack and the lab upstream registry (generates .env, exports the CA)
	registry/up.sh
	lab-registry/up.sh

registry-down: ## stop the stack and the lab registry (volumes kept; registry/down.sh --volumes wipes)
	lab-registry/down.sh
	registry/down.sh

bootstrap: ## repositories, scan policy, users ci and developer, tokens (idempotent)
	registry/bootstrap.sh

client: ## build the workstation image: Node, Claude Code, mcp-publisher, skopeo, mcp-call, the CA
	client/build.sh

publish: ## step 2: npm package, image, then server.json with mcp-publisher (ci token)
	flows/publish.sh

clients: ## step 2: what VS Code and Copilot read; Claude Code mcp add/list; a real tool call
	flows/clients.sh

curate: ## step 3: Remote mcp-upstream, sync, approval queue, deny list, pins, drift
	flows/curate.sh

supply-chain: ## step 4: own-repos refusals, digest pin and tag move, quarantine, the lint
	flows/supply-chain.sh

ci: ## step 5: GitHub Actions OIDC, mcp-publisher login github-oidc, namespace grant
	flows/ci.sh

virtual: ## step 6: Virtual mcp = mcp-internal + mcp-upstream, hosted shadows remote
	flows/virtual.sh

bundles: ## step 7: signed MCPB bundles, download tickets, capability snapshots and diffs
	flows/bundles.sh

gates: ## run G1-G9 (PASS / FAIL / BLOCKED per check), results in out/gates/
	gates/run-all.sh

screens: ## web UI screenshots into out/screens/ (Playwright on ak-mcp-net)
	screens/shoot.sh

screens-ready: ## print the UI URL and where the credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30448}  (certificate from the stack's internal CA)"
	@echo "CA:        $(CURDIR)/registry/out/ak-internal-ca.crt"
	@echo "Admin:     user admin, password = ADMIN_PASSWORD in $(CURDIR)/registry/.env"
	@echo "Developer: user developer, password in $(CURDIR)/registry/.tokens/developer.password"

all: registry-up bootstrap client publish clients curate supply-chain ci virtual bundles ## everything except the gates, from an empty registry
	@echo "all: done. Next: make gates"

clean: ## remove the stack, its volumes and network, the lab registry, images built here and all local state
	lab-registry/down.sh
	registry/clean.sh
