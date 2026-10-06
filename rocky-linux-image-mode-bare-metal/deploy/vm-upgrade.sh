#!/usr/bin/env bash
# Day-2 upgrade, the way a fleet would see it:
#   1. "promote" a tested build by retagging it in Artifact Keeper
#      (PROMOTE_FROM -> IMAGE, e.g. rocky-edge:10.2-4 -> rocky-edge:10). The copy reads
#      the source through the build-host signature policy, and the cosign signature
#      (bound to the digest) covers the new tag without re-signing;
#   2. in the node: bootc upgrade (pulls the new digest for the tracked tag) + reboot;
#   3. verify the new digest is booted and the old one is the rollback entry.
# PROMOTE_FROM= (empty) skips step 1 and just upgrades to whatever the tag points at.
source "$(dirname "$0")/lib.sh"
PROMOTE_FROM="${PROMOTE_FROM-rocky-edge:10.2-4}"
TOKEN_FILE="${TOKEN_FILE:-$REPO_ROOT/registry/.ak-token}"

vm_running || die "VM is not running; 'make vm-boot' first"
wait_ssh 600 10

digests() { vssh 'bootc status --format=json' | jq -r "$1"; }
old="$(digests '.status.booted.image.imageDigest')"
tracked="$(digests '.status.booted.image.image.image')"
log "booted: $tracked@$old"

if [[ -n "$PROMOTE_FROM" ]]; then
  src="$HOST_REGISTRY/$IMAGE_REPO/$PROMOTE_FROM" dst="$HOST_REGISTRY/$IMAGE_REF"
  if [[ -r "$TOKEN_FILE" ]]; then
    skopeo login --tls-verify=false -u admin --password-stdin "$HOST_REGISTRY" < "$TOKEN_FILE" >/dev/null
  fi
  log "promote: $src -> $dst"
  t0=$SECONDS
  skopeo copy --src-tls-verify=false --dest-tls-verify=false "docker://$src" "docker://$dst"
  stamp "upgrade: promote copy took $((SECONDS - t0))s"
  log "tag now: $(skopeo inspect --no-creds --tls-verify=false "docker://$dst" | jq -r .Digest)"
fi

printf '\n=== bootc upgrade ===\n'
t0=$SECONDS
vssh 'bootc upgrade'
stamp "upgrade: bootc upgrade (pull+stage) took $((SECONDS - t0))s"
staged="$(digests '.status.staged.image.imageDigest // empty')"
[[ -n "$staged" ]] || die "bootc upgrade staged nothing (registry tag still points at the booted digest?)"
log "staged: $staged"

t0=$SECONDS
reboot_and_wait
stamp "upgrade: reboot to ssh took $((SECONDS - t0))s"

printf '\n=== bootc status ===\n'; vssh 'bootc status'
now="$(digests '.status.booted.image.imageDigest')"
rb="$(digests '.status.rollback.image.imageDigest // empty')"
printf '\n=== MOTD (as shown at login) ===\n'; vssh 'cat /etc/motd 2>/dev/null; for f in /etc/motd.d/*; do [ -f "$f" ] && cat "$f"; done; true'
printf '\n=== /etc/motd.d/edge ===\n'; vssh 'cat /etc/motd.d/edge' || log "no /etc/motd.d/edge in this image"
printf '\n=== edge-site-config ===\n'; vssh 'rpm -q edge-site-config' || true

if [[ "$now" != "$staged" ]]; then
  # A staged deployment is written to /boot by ostree-finalize-staged.service at
  # shutdown; if that fails the node silently boots the old one. The reason is
  # reported by ostree-boot-complete.service on the following boot.
  vssh 'journalctl -b -u ostree-boot-complete.service --no-pager | tail -5' || true
  die "booted digest $now != staged $staged (staged deployment was not finalized)"
fi
[[ "$rb" == "$old" ]]     || die "rollback digest $rb != previous booted $old"
stamp "upgrade: OK booted=$now rollback=$old"
