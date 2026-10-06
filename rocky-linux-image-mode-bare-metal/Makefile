# Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth.
# Pipeline: registry-up -> keys -> publish-keys -> base -> rpm -> image -> push -> sign -> verify
#           -> (deploy/deploy.mk: vm-*)
# Iteration 2: everything is signed (RPMs: GPG, repodata: Artifact Keeper GPG,
# images: cosign by digest) and every consumer verifies. See signing/README.md.
# Every target is re-runnable. No sudo anywhere; rootless podman only.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

AK            ?= localhost:30080
EDGE_REPO     := $(AK)/oci-bootc/rocky-edge
# edge-site-config releases built into rocky-edge:<osver>-<rel>
# (1/2 = iteration 1, unsigned; 3/4 = signed baseline / signed day-2)
RELEASES      ?= 3 4
# release the floating tag rocky-edge:10 points at (make promote REL=4 for day-2)
REL           ?= 3

.PHONY: help registry-up registry-down keys publish-keys base base-rebuild rpm rpm-build rpm-upload \
        image push unsigned-test sign verify promote all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

registry-up: ## start Artifact Keeper and create repos/token/edge.repo (idempotent)
	registry/up.sh
	registry/bootstrap.sh

registry-down: ## stop Artifact Keeper (volumes kept)
	registry/down.sh

keys: ## create cosign + RPM GPG keys, fetch vendor keys (signing/keys/, gitignored; idempotent)
	signing/gen-keys.sh

publish-keys: ## upload public keys to the raw-edge-keys repo and check anonymous download
	signing/publish-keys.sh

base: ## build RESF rocky-bootc base rootless (skips if built), lint, push + cosign-sign oci-bootc/rocky-bootc-base:10
	base/build.sh

base-rebuild: ## force a fresh base build and push
	REBUILD=1 base/build.sh

rpm: rpm-build rpm-upload ## build + rpmsign edge-site-config 1.0-{3,4} and upload to rpm-edge-site

rpm-build:
	RELEASES="$(RELEASES)" rpms/build.sh

rpm-upload:
	rpms/upload.sh

image: ## build + smoke-test localhost/rocky-edge:<osver>-<rel> for each of RELEASES
	for r in $(RELEASES); do SITE_RELEASE=$$r image/build.sh; done

push: ## push + cosign-sign rocky-edge:<osver>-<rel> tags and point rocky-edge:10 at release $(REL)
	RELEASES="$(RELEASES)" FLOAT_RELEASE="$(REL)" image/push.sh

unsigned-test: ## build + push rocky-edge:unsigned-test (release 4 + a label, NOT signed) for negative tests
	SITE_RELEASE=4 LOCAL_TAG=unsigned-test EXTRA_LABEL=edge.test=unsigned image/build.sh
	RELEASES="$(REL)" FLOAT_RELEASE="$(REL)" EXTRA_TAGS=unsigned-test image/push.sh

sign: ## cosign-sign (by digest) the base and every rocky-edge <osver>-<rel> tag in RELEASES; no-op if already signed
	signing/sign-image.sh $(AK)/oci-bootc/rocky-bootc-base:10 \
	  $$(skopeo list-tags --no-creds --tls-verify=false docker://$(EDGE_REPO) \
	     | jq -r --arg r "$(RELEASES)" '.Tags[] | select(test("^[0-9.]+-(" + ($$r | gsub(" "; "|")) + ")$$"))' \
	     | sed 's|^|$(EDGE_REPO):|')

verify: ## check keys, cosign signatures, build-host policy, repodata and RPM signatures
	RELEASES="$(RELEASES)" signing/verify.sh

promote: ## move rocky-edge:10 to release $(REL) (registry-side copy), e.g. make promote REL=4
	RELEASES="$(REL)" FLOAT_RELEASE="$(REL)" image/push.sh

# preflight and vm-all live in deploy/deploy.mk:
#   make preflight   check tools, rootless podman, /dev/kvm, vm.max_map_count, SSH key, ports
#   make vm-all      vm-install vm-boot vm-verify vm-upgrade-unsigned vm-upgrade vm-verify vm-rollback vm-verify

all: registry-up keys publish-keys base rpm image push unsigned-test sign verify ## everything up to signed, verified edge images

clean: ## remove local build scratch (not images, not registry data)
	rm -rf base/.work rpms/.work rpms/out image/.work

-include deploy/deploy.mk
