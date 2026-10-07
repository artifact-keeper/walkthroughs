#!/usr/bin/env bash
# G13 Image: the application image builds from the registry only (build host on
# build-isolated, cold storage), is signed in oci-apps, and runs (also with no network).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G13; PROJECT="${PROJECT:-project-direct}"; GATE="${ATTESTATION_GATE:-enforce}"
podman volume rm -f ak-conda-builder-g13 >/dev/null 2>&1
log="$GOUT/g13-build.log"; s0=$SECONDS
if NETWORK="$ISOLATED_NET" BUILDER_VOLUME=ak-conda-builder-g13 TAG=1.0.0 ATTESTATION_GATE="$GATE" PROJECT="$PROJECT" \
   "$ROOT/image/build.sh" > "$log" 2>&1; then
  grep -E '^\[[12]/2\] STEP 1/|FROM|verify:' "$log" | head -6
  pass $G "image builds on build-isolated from a cold builder ($((SECONDS - s0)) s; base images, pixi packages, cosign/jq/curl all from ak.internal; attestation gate: $GATE)"
else fail $G "isolated image build" "$(tail -3 "$log" | tr '\n' ' ')"; exit 0; fi
"$ROOT/image/push.sh" > "$GOUT/g13-push.log" 2>&1 && ref=$(<"$ROOT/image/.work/pushed-ref")
export DOCKER_CONFIG="$ROOT/image/.work/docker" SSL_CERT_FILE="$ROOT/image/.work/ca-bundle.crt"
if cosign verify --key "$ROOT/signing/keys/cosign.pub" --insecure-ignore-tlog "$ref" >/dev/null 2>&1; then pass $G "pushed to oci-apps and cosign-verified: $ref"
else fail $G "cosign verify" "$ref"; fi
if ! cosign verify --key "$ROOT/signing/keys/wrong/cosign.pub" --insecure-ignore-tlog "$ref" >/dev/null 2>&1; then pass $G "verification with an untrusted key fails"; else fail $G "wrong key verifies"; fi
out=$(podman run --rm --network none localhost/acme-analytics:1.0.0 2>&1); echo "$out" | tail -4
grep -q 'acme-report' <<<"$out" && pass $G "image runs with --network none (acme-report via the pixi shell-hook entrypoint)" || fail $G "image runs" "$(tail -1 <<<"$out")"
lbl=$(podman image inspect localhost/acme-analytics:1.0.0 --format '{{index .Labels "acme.attestation-gate"}}')
[[ $lbl == enforce ]] || echo "note: image label acme.attestation-gate=$lbl (built with ATTESTATION_GATE=$GATE)"
