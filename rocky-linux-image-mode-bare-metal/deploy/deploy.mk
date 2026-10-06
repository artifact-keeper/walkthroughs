# deploy/deploy.mk -- VM harness targets, included by the root Makefile
# (`-include deploy/deploy.mk`). Works standalone too: make -f deploy/deploy.mk vm-status
#
# Override anything from lib.sh on the command line, e.g.
#   make vm-install IMAGE=rocky-edge:dev
#   make vm-upgrade PROMOTE_FROM=rocky-edge:10.2-4
#   make vm-upgrade-unsigned               # negative test: unsigned image must be refused
#   make vm-upgrade PROMOTE_FROM=          # no retag, just bootc upgrade
#   make vm-clean vm-all                   # the whole VM sequence from a fresh disk

DEPLOY := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: vm-install vm-boot vm-verify vm-ssh vm-upgrade vm-upgrade-unsigned vm-rollback vm-stop vm-clean vm-status ks-render vm-all preflight

ks-render:   ; $(DEPLOY)/render-ks.sh
vm-install:  ; $(DEPLOY)/vm-install.sh
vm-boot:     ; $(DEPLOY)/vm-boot.sh
vm-verify:   ; $(DEPLOY)/vm-verify.sh
vm-ssh:      ; $(DEPLOY)/vm-ssh.sh
vm-upgrade:  ; $(DEPLOY)/vm-upgrade.sh
vm-upgrade-unsigned: ; $(DEPLOY)/vm-upgrade-unsigned.sh
vm-rollback: ; $(DEPLOY)/vm-rollback.sh
vm-stop:     ; $(DEPLOY)/vm-stop.sh
vm-clean:    ; $(DEPLOY)/vm-clean.sh
vm-status:   ; $(DEPLOY)/vm-status.sh
preflight: ## check tools, rootless podman, /dev/kvm, vm.max_map_count, SSH key, free ports
	$(DEPLOY)/preflight.sh

# The full VM sequence. make builds each goal once per invocation, so
# `make vm-verify vm-upgrade vm-verify` would verify only once; this target runs the
# scripts in order as plain recipe lines instead, stopping at the first failure.
vm-all: ## vm-install, vm-boot, vm-verify, vm-upgrade-unsigned, vm-upgrade, vm-verify, vm-rollback, vm-verify
	$(DEPLOY)/vm-install.sh
	$(DEPLOY)/vm-boot.sh
	$(DEPLOY)/vm-verify.sh
	$(DEPLOY)/vm-upgrade-unsigned.sh
	$(DEPLOY)/vm-upgrade.sh
	$(DEPLOY)/vm-verify.sh
	$(DEPLOY)/vm-rollback.sh
	$(DEPLOY)/vm-verify.sh
