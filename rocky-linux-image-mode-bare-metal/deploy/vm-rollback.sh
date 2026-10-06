#!/usr/bin/env bash
# bootc rollback + reboot; verify the previous deployment is booted again.
source "$(dirname "$0")/lib.sh"
vm_running || die "VM is not running; 'make vm-boot' first"
wait_ssh 600 10

digests() { vssh 'bootc status --format=json' | jq -r "$1"; }
cur="$(digests '.status.booted.image.imageDigest')"
want="$(digests '.status.rollback.image.imageDigest // empty')"
[[ -n "$want" ]] || die "no rollback deployment available"
log "booted $cur; rolling back to $want"

printf '\n=== bootc rollback ===\n'; vssh 'bootc rollback'
t0=$SECONDS
reboot_and_wait
stamp "rollback: reboot to ssh took $((SECONDS - t0))s"

printf '\n=== bootc status ===\n'; vssh 'bootc status'
printf '\n=== /etc/motd.d/edge ===\n'; vssh 'cat /etc/motd.d/edge' || true
now="$(digests '.status.booted.image.imageDigest')"
[[ "$now" == "$want" ]] || die "booted digest $now, expected $want"
stamp "rollback: OK booted=$now rollback=$cur"
