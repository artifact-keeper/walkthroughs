# shellcheck shell=bash
# Shared cosign settings for signing/*.sh, image/push.sh and base/build.sh.
SIGNING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SIGNING_DIR/.." && pwd)"
AK="${AK:-localhost:30080}"
COSIGN_KEY="${COSIGN_KEY:-$SIGNING_DIR/keys/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-$SIGNING_DIR/keys/pub/edge-cosign.pub}"
# PoC: the cosign key has an empty password (signing/README.md).
export COSIGN_PASSWORD="${COSIGN_PASSWORD-}"
# cosign (go-containerregistry) does not read podman's auth.json; give it a
# docker-style config dir of its own, written by `podman login --authfile`.
export DOCKER_CONFIG="${DOCKER_CONFIG:-$SIGNING_DIR/keys/docker}"
# cosign 3 defaults to the new Sigstore bundle format stored via the OCI referrers
# API and to Rekor/Fulcio service discovery. containers-image (podman, skopeo, bootc,
# Anaconda) only understands the classic "sigstore attachment" (sha256-<digest>.sig
# tag, simple-signing payload), and an edge network has no Rekor. So: legacy format,
# no transparency log, no TUF signing config. These flags are hidden/deprecated in
# cosign 3.1 and print a deprecation warning.
COSIGN_SIGN_FLAGS=(--yes --key "$COSIGN_KEY" --allow-http-registry --allow-insecure-registry
                   --tlog-upload=false --new-bundle-format=false --use-signing-config=false)
COSIGN_VERIFY_FLAGS=(--key "$COSIGN_PUB" --allow-http-registry --allow-insecure-registry
                     --insecure-ignore-tlog)

cosign_login() {
  [[ -s "$DOCKER_CONFIG/config.json" ]] && return 0
  mkdir -p "$DOCKER_CONFIG"; chmod 700 "$DOCKER_CONFIG"
  podman login --tls-verify=false --authfile "$DOCKER_CONFIG/config.json" -u admin --password-stdin "$AK" \
    < "$REPO_ROOT/registry/.ak-token" >/dev/null
}

# digest_of REF -> sha256:... (manifest digest as stored in the registry)
digest_of() { skopeo inspect --no-creds --tls-verify=false "docker://$1" | jq -r .Digest; }

# cosign_sign_ref REF(tag) -> signs REPO@DIGEST, prints the digest
cosign_sign_ref() {
  local ref=$1 repo d
  repo="${ref%:*}"; d="$(digest_of "$ref")"
  [[ -s "$COSIGN_KEY" ]] || { echo "sign: $COSIGN_KEY missing; run signing/gen-keys.sh (make keys)" >&2; return 1; }
  cosign_login
  # Idempotent: a digest that already verifies is not signed again (cosign would
  # append a second, identical-key signature layer to the .sig manifest).
  if cosign verify "${COSIGN_VERIFY_FLAGS[@]}" "$repo@$d" >/dev/null 2>&1; then
    echo "$d"; return 0
  fi
  cosign sign "${COSIGN_SIGN_FLAGS[@]}" "$repo@$d" 2>&1 \
    | grep -v -e 'Flag --.* has been deprecated' -e '^Signing artifact' >&2 || true
  cosign verify "${COSIGN_VERIFY_FLAGS[@]}" "$repo@$d" >/dev/null 2>&1 \
    || { echo "sign: cosign verify failed for $repo@$d right after signing" >&2; return 1; }
  echo "$d"
}
