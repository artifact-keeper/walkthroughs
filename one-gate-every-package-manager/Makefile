# One gate for every package manager, on Artifact Keeper (1.12.0 line, run against main).
# Pipeline: registry-up -> bootstrap -> record -> baseline -> known-bad -> preview
#           -> enforce -> baseline (again) -> known-bad (again) -> review -> exception -> gates
# Every target is re-runnable. No sudo; rootless podman only. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# The severity at or above which a finding refuses a file (critical|high|medium|low).
THRESHOLD ?= high

.PHONY: help registry-up registry-down bootstrap images record baseline known-bad preview enforce fail-open \
        lock unlock review exception vendor acknowledge rescan proxied gates all clean screens-ready

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

registry-up: ## start the ak-gate stack (generates .env and secrets, exports the CA)
	registry/up.sh

registry-down: ## stop the stack (volumes kept; registry/down.sh --volumes wipes)
	registry/down.sh

bootstrap: ## the five proxies, npm-internal with its scan policy, tokens, index signing keys (idempotent)
	registry/bootstrap.sh

images: ## pull the five client images (official images, straight from Docker Hub)
	clients/pull-images.sh

record: ## step 2: the gate in record-only mode on all five proxies (scan, record, never withhold)
	THRESHOLD=$(THRESHOLD) policy/mode.sh record_only
	policy/wait-scanner.sh

# PHASE names the directory under clients/out/ the client logs go to (record, enforce).
# BASELINE=fixed runs the projects in clients/baseline-fixed/ (the pins after the review).
PHASE ?= run
BASELINE ?=

baseline: ## what each package manager fetches on an ordinary day (download only); logs in clients/out/$(PHASE)/
	PHASE=$(PHASE) BASELINE=$(BASELINE) clients/baseline.sh

known-bad: ## one package with a published advisory per package manager (download only); logs in clients/out/$(PHASE)/
	-PHASE=$(PHASE) clients/known-bad.sh

preview: ## step 2: what would be blocked, from the recorded verdicts
	THRESHOLD=$(THRESHOLD) policy/preview.sh

enforce: ## step 4: fail_closed on all five proxies
	THRESHOLD=$(THRESHOLD) policy/mode.sh fail_closed

fail-open: ## the middle setting: known-bad refused, first pulls served while scanned
	THRESHOLD=$(THRESHOLD) policy/mode.sh fail_open

lock: ## step 4: instance-admin lock: repository admins cannot weaken the policy
	policy/lock.sh on

unlock: ## hand the policy back to repository admins
	policy/lock.sh off

review: ## step 3: dashboard, blocked list, hold queues, scores, refusal audit rows
	policy/review.sh

vendor: ## step 5: publish the vendored lodash 4.17.15 to npm-internal; upload scan refuses it
	exception/vendor.sh

acknowledge: ## step 5: acknowledge its findings with a reason; download allowed
	exception/acknowledge.sh

rescan: ## step 5: scan it again; the acknowledgement does not survive (#5153)
	exception/rescan.sh

proxied: ## step 5: a proxied false positive (async-ctrlc 1.2.0, #5143) has no exception
	exception/proxied.sh

exception: vendor acknowledge rescan proxied ## step 5, all four parts

gates: ## run G1-G9 (PASS / FAIL / BLOCKED per gate), evidence in out/gates/
	THRESHOLD=$(THRESHOLD) gates/run-all.sh

all: registry-up bootstrap images record ## the whole story, from an empty registry (steps 1 to 5)
	$(MAKE) baseline known-bad PHASE=record
	$(MAKE) preview
	$(MAKE) baseline PHASE=record-fixed BASELINE=fixed
	$(MAKE) preview
	$(MAKE) enforce lock
	-$(MAKE) baseline PHASE=enforce BASELINE=fixed
	-$(MAKE) baseline PHASE=enforce-warm BASELINE=fixed
	$(MAKE) known-bad PHASE=enforce
	$(MAKE) review
	$(MAKE) exception

clean: ## delete the stack and all state: containers, volumes, network, tokens, outputs
	registry/clean.sh

screens-ready: ## print the UI URL and where the admin credentials are
	@echo "UI:        https://127.0.0.1:$${HTTPS_PORT:-30446}  (certificate from the stack's internal CA)"
	@echo "Login:     admin / ADMIN_PASSWORD in registry/.env"
