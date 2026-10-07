# Private conda channel for pixi, with supply-chain controls, on Artifact Keeper.
# Pipeline: registry-up -> bootstrap -> keys -> client -> packages -> publish -> attest
#           -> scan-hosted -> promote -> lock -> image -> scan -> gates
# Every target is re-runnable. No sudo; rootless podman only. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# project/ = one virtual channel (target design); project-direct/ = internal +
# conda-forge mirror (works on Artifact Keeper main today).
PROJECT ?= project
SCRATCH ?= $(abspath ../../conda-walkthrough)

.PHONY: help registry-up registry-down bootstrap keys publish-keys client packages publish attest \
        scan-hosted promote lock install image push sign scan gates screens-ready all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

registry-up: ## start the ak-conda stack (generates .env and secrets, exports the CA)
	registry/up.sh

registry-down: ## stop the stack (volumes kept; registry/down.sh --volumes wipes)
	registry/down.sh

bootstrap: ## repositories, release gate policy, tokens, podman auth, CA in `trust` (idempotent)
	registry/bootstrap.sh

keys: ## cosign key pairs for the CI signer and a wrong key for negative tests
	signing/gen-keys.sh

publish-keys: ## publish the CI verification key to the trust repo
	signing/publish-keys.sh

client: ## build the pixi client image (CLIENT_SHARDS=on drops the shard workaround)
	client/build.sh

packages: ## rattler-build the acme-* packages through the registry
	packages/build.sh

publish: ## upload packages to conda-staging (rattler-build upload artifactory, CI token)
	packages/publish.sh

attest: ## CEP-27 attestations signed with the CI key, uploaded beside each package
	packages/attest.sh

scan-hosted: ## trigger and wait for the registry's scans of conda-staging
	packages/scan.sh conda-staging

promote: ## promote staging -> conda-internal through the release gate
	packages/promote.sh

lock: ## pixi lock for $(PROJECT) inside a client container on ak-conda-net
	$(PROJECT)/pixi-run.sh lock

install: ## pixi install --locked for $(PROJECT) in a client container
	$(PROJECT)/pixi-run.sh install --locked

image: ## build localhost/acme-analytics (registry only, attestation gate) from $(PROJECT)
	PROJECT=$(PROJECT) image/build.sh

push: ## push the image to oci-apps and cosign-sign it by digest
	image/push.sh

scan: ## Syft + Grype on the image and the environment; registry SBOM + PURL lookup
	scan/scan.sh

gates: ## run G1-G13 (PASS / FAIL / BLOCKED per gate), results in out/gates/
	gates/run-all.sh

screens-ready: ## print the UI URL and where the admin credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30444}  (self-signed by the stack's internal CA)"
	@echo "CA:        $(CURDIR)/registry/out/ak-internal-ca.crt"
	@echo "Admin:     user admin, password = ADMIN_PASSWORD in $(CURDIR)/registry/.env"
	@echo "Consumer:  user consumer, password in $(CURDIR)/registry/.tokens/consumer.password"
	@echo "In network: https://ak.internal (podman networks ak-conda-net, build-isolated)"

all: registry-up bootstrap keys publish-keys client packages publish attest scan-hosted promote lock image push scan gates ## everything

clean: ## remove local build outputs (not the registry's data, not keys or tokens)
	rm -rf packages/out image/.work client/.work out
