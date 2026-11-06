# The off-grid AI stack on Artifact Keeper: a local model, MCP tools, agent plugins and every
# package under them from one registry, then the network is cut and an agent still works.
# Pipeline: registry-up -> bootstrap -> seed -> vet -> disconnect -> agent -> pi
#           (then: make gates)
# No sudo; rootless podman only. See README.md. SMALL_MODEL=1 uses Qwen2.5-0.5B instead of
# Qwen2.5-1.5B (seed/manifest.toml).
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

.PHONY: help registry-up registry-down bootstrap lock seed vet disconnect agent pi reconnect \
        gates all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

registry-up: ## start the ak-offgrid stack and the egress ledger on the current network (generates .env)
	registry/up.sh
	ledger/up.sh

registry-down: ## stop the stack, the ledger and llama-server (volumes kept; registry/down.sh --volumes wipes)
	podman rm -f -t 0 --ignore ak-offgrid-llama >/dev/null
	ledger/down.sh
	registry/down.sh

bootstrap: ## every repository, the offline settings and the ledger on every Remote, users and tokens
	registry/bootstrap.sh

lock: ## re-resolve agent/requirements.lock (hash-pinned) through the registry
	agent/lock.sh

seed: ## step 2: pull everything in seed/manifest.toml through the registry; out/inventory/seed.tsv
	seed/seed.sh

vet: ## step 3: the model into hf-models (model-file scanner), the offline scanner adapter, the config export
	flows/vet.sh

disconnect: ## step 4: cache-only Remotes, jobs paused, the stack moved to the internal site network
	flows/disconnect.sh

agent: ## step 5: llama-server and the agent on the site network, from the registry alone
	flows/agent.sh

pi: ## step 6: pi, an open-source coding agent, gets the plugin offline and calls its MCP tool
	flows/pi.sh

reconnect: ## undo disconnect: back to the seed network, Remotes online, jobs resumed
	flows/reconnect.sh

gates: ## run G1-G7 (PASS / FAIL / BLOCKED per check), results in out/gates/
	gates/run-all.sh

all: registry-up bootstrap seed vet disconnect agent pi ## everything except the gates, from an empty registry
	@echo "all: done. Next: make gates"

clean: ## remove the stack, its volumes and networks, the ledger, llama-server, the images and all local state
	podman rm -f -t 0 --ignore ak-offgrid-llama >/dev/null
	ledger/down.sh
	registry/clean.sh
