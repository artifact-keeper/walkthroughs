# A private Hugging Face model hub on Artifact Keeper (huggingface repository type).
# Pipeline: registry-up -> bootstrap -> client -> proxy -> gated -> allowlist -> host -> hold
#           -> freeze   (then: make gates)
# No sudo; rootless podman only. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

.PHONY: help registry-up registry-down bootstrap client proxy gated allowlist host hold freeze \
        gates screens screens-ready all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

registry-up: ## start the ak-hf stack and the lab Hub (generates .env, exports the CA)
	registry/up.sh
	lab-hub/up.sh

registry-down: ## stop the stack and the lab Hub (volumes kept; registry/down.sh --volumes wipes)
	lab-hub/down.sh
	registry/down.sh

bootstrap: ## package proxies, hf-hub and hf-lab (frozen), users and tokens (idempotent)
	registry/bootstrap.sh

client: ## build the ML workstation image through the registry (python, torch, transformers, ...)
	client/build.sh

proxy: ## step 2: snapshot_download, hf download and encode through hf-lab and hf-hub
	flows/proxy.sh

gated: ## step 3: a gated model through a Remote that holds the Hub token; group ml-team
	flows/gated.sh

allowlist: ## step 4: hf-curated, an upstream filter that admits approved organizations only
	flows/allowlist.sh

host: ## step 5: hf-local (publish a model file by file), hf-models (Virtual)
	flows/host.sh

hold: ## step 6: hf-staging: upload hold, scan on upload, block_unscanned, release and reject
	flows/hold.sh

freeze: ## step 7: seed, disconnect, use the models from a workstation with no route out
	flows/freeze.sh

gates: ## run G1-G8 (PASS / FAIL / BLOCKED per check), results in out/gates/
	gates/run-all.sh

screens: ## web UI screenshots into out/screens/ (Playwright on ak-hf-net)
	screens/shoot.sh

screens-ready: ## print the UI URL and where the credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30449}  (certificate from the stack's internal CA)"
	@echo "CA:        $(CURDIR)/registry/out/ak-internal-ca.crt"
	@echo "Admin:     user admin, password = ADMIN_PASSWORD in $(CURDIR)/registry/.env"

all: registry-up bootstrap client proxy gated allowlist host hold freeze ## everything except the gates, from an empty registry
	@echo "all: done. Next: make gates"

clean: ## remove the stack, its volumes and networks, the lab Hub, the workstation image and all local state
	lab-hub/down.sh
	registry/clean.sh
