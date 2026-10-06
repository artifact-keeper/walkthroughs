#!/usr/bin/env bash
# Day-2 NEGATIVE test (gate 6): promote an UNSIGNED image to the tag the node tracks,
# run `bootc upgrade`, and require that it fails with the signature-policy error,
# that nothing is staged and that the node keeps running the image it booted.
# Afterwards the tag is put back on the digest it pointed at before.
#   UNSIGNED_FROM (default rocky-edge:unsigned-test)
source "$(dirname "$0")/lib.sh"
UNSIGNED_FROM="${UNSIGNED_FROM:-rocky-edge:unsigned-test}"
TOKEN_FILE="${TOKEN_FILE:-$REPO_ROOT/registry/.ak-token}"
OUT="$STATE_DIR/upgrade-unsigned.log"

vm_running || die "VM is not running; 'make vm-boot' first"
wait_ssh 600 10
# shellcheck source=/dev/null
source "$DEPLOY_DIR/k8s-detect.sh"

digests() { vssh 'bootc status --format=json' | jq -r "$1"; }
booted="$(digests '.status.booted.image.imageDigest')"
log "booted: $(digests '.status.booted.image.image.image') @ $booted"
log "origin transport/sigverify: $(vssh 'grep -h "^container-image-reference" /ostree/deploy/*/deploy/*.origin | sort -u' || true)"

src="$HOST_REGISTRY/$IMAGE_REPO/$UNSIGNED_FROM" dst="$HOST_REGISTRY/$IMAGE_REF"
prev="$(skopeo inspect --no-creds --tls-verify=false "docker://$dst" | jq -r .Digest)"
[[ -r "$TOKEN_FILE" ]] && skopeo login --tls-verify=false -u admin --password-stdin "$HOST_REGISTRY" < "$TOKEN_FILE" >/dev/null
restore() {
  skopeo copy -q --src-tls-verify=false --dest-tls-verify=false \
    "docker://$HOST_REGISTRY/$IMAGE_REPO/${IMAGE%%:*}@$prev" "docker://$dst" \
    && log "restored $dst -> $prev"
}
trap restore EXIT
# --insecure-policy: our own build-host policy would refuse to read the unsigned
# source; here we deliberately let it through so that the NODE has to reject it.
log "promote (unsigned!): $src -> $dst"
skopeo copy -q --insecure-policy --src-tls-verify=false --dest-tls-verify=false "docker://$src" "docker://$dst"
log "tag now: $(skopeo inspect --no-creds --tls-verify=false "docker://$dst" | jq -r .Digest)"

printf '\n=== bootc upgrade (must fail) ===\n'
t0=$SECONDS
if vssh 'bootc upgrade' > "$OUT" 2>&1; then
  cat "$OUT"; die "bootc upgrade of an UNSIGNED image succeeded; the node policy is not enforced"
fi
cat "$OUT"
stamp "upgrade-unsigned: bootc upgrade refused after $((SECONDS - t0))s"
grep -qE 'A signature was required|Source image rejected|signature' "$OUT" \
  || die "bootc upgrade failed, but not with a signature error (see $OUT)"

staged="$(digests '.status.staged.image.imageDigest // empty')"
now="$(digests '.status.booted.image.imageDigest')"
[[ -z "$staged" ]] || die "something was staged ($staged) despite the failure"
[[ "$now" == "$booted" ]] || die "booted digest changed: $now"
vssh "systemctl is-active $K8S_UNIT" >/dev/null || die "$K8S_UNIT not active"
vssh "$KUBECTL get nodes --no-headers" | awk '{print "node: "$1" "$2}'
stamp "upgrade-unsigned: OK (refused; still booted $booted, nothing staged, $K8S_UNIT active)"
