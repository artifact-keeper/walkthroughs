#!/usr/bin/env bash
# Push the locally built edge images to Artifact Keeper, cosign-sign each pushed
# digest, and move the floating tag.
#   localhost/rocky-edge:<osver>-<rel>  ->  $AK/oci-bootc/rocky-edge:<osver>-<rel>  (signed)
#   $AK/oci-bootc/rocky-edge:10         ->  points at <osver>-$FLOAT_RELEASE (default 3)
# Promotion is a plain registry-side tag copy: cosign signatures bind to the manifest
# digest, so :10 is covered by the signature of the release it points at.
# Extra tags (not releases): EXTRA_TAGS="unsigned-test" pushes localhost/rocky-edge:<tag>
#   as-is and does NOT sign it (negative tests). SIGN=0 skips signing entirely.
# Env: RELEASES (default "3 4"), FLOAT_RELEASE (default 3), AK (default localhost:30080),
#      EXTRA_TAGS, SIGN (default 1),
#      READY_FILE (optional path; the digest of :10 is written there after push)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
RELEASES="${RELEASES:-3 4}"
FLOAT_RELEASE="${FLOAT_RELEASE:-3}"
EXTRA_TAGS="${EXTRA_TAGS:-}"
SIGN="${SIGN:-1}"
REPO="$AK/oci-bootc/rocky-edge"
log() { echo "push: $*"; }

"$HERE/setup-host.sh" >/dev/null
podman login --tls-verify=false -u admin --password-stdin "$AK" < "$ROOT/registry/.ak-token" >/dev/null
OSVER="${OSVER:-$(podman run --rm "$AK/oci-bootc/rocky-bootc-base:10" sh -c '. /usr/lib/os-release; echo "$VERSION_ID"')}"

for r in $RELEASES; do
  tag="$OSVER-$r"
  podman image exists "localhost/rocky-edge:$tag" || { echo "push.sh: localhost/rocky-edge:$tag not built (SITE_RELEASE=$r image/build.sh)" >&2; exit 1; }
  start=$(date +%s)
  # --remove-signatures: never carry over local signatures; the pushed digest is signed below.
  podman push --remove-signatures --tls-verify=false "localhost/rocky-edge:$tag" "docker://$REPO:$tag"
  log "$REPO:$tag pushed in $(( $(date +%s) - start ))s"
  if [[ "$SIGN" == 1 ]]; then
    start=$(date +%s)
    "$ROOT/signing/sign-image.sh" "$REPO:$tag"
    log "$REPO:$tag signed in $(( $(date +%s) - start ))s"
  fi
done

for t in $EXTRA_TAGS; do
  podman image exists "localhost/rocky-edge:$t" || { echo "push.sh: localhost/rocky-edge:$t not built" >&2; exit 1; }
  podman push --remove-signatures --tls-verify=false "localhost/rocky-edge:$t" "docker://$REPO:$t"
  log "$REPO:$t pushed UNSIGNED (negative-test image)"
done

# Floating tag: registry-side copy, so :10 and :<osver>-N share one manifest digest.
# The copy reads the source through the build-host policy (image/setup-host.sh), so
# promoting an unsigned image fails here already. FLOAT_TAG=<tag> FLOAT_INSECURE=1
# (used only by the day-2 negative test) bypasses that so the NODE is what rejects it.
FLOAT_TAG="${FLOAT_TAG:-$OSVER-$FLOAT_RELEASE}"
policy=(); [[ "${FLOAT_INSECURE:-0}" == 1 ]] && policy=(--insecure-policy)
skopeo copy "${policy[@]}" --src-tls-verify=false --dest-tls-verify=false \
  "docker://$REPO:$FLOAT_TAG" "docker://$REPO:10"

for t in 10 $(for r in $RELEASES; do echo "$OSVER-$r"; done) $EXTRA_TAGS; do
  d="$(skopeo inspect --no-creds --tls-verify=false "docker://$REPO:$t" | jq -r .Digest)"
  if cosign verify --key "$ROOT/signing/keys/pub/edge-cosign.pub" --allow-http-registry --insecure-ignore-tlog \
       "$REPO@$d" >/dev/null 2>&1; then sig=signed; else sig=UNSIGNED; fi
  printf 'push: %-44s %s  %s\n' "$REPO:$t" "$d" "$sig"
done
if [[ -n "${READY_FILE:-}" ]]; then
  skopeo inspect --no-creds --tls-verify=false "docker://$REPO:10" | jq -r .Digest > "$READY_FILE"
  log "wrote digest of $REPO:10 to $READY_FILE"
fi
