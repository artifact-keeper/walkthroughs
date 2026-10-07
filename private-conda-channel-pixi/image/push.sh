#!/usr/bin/env bash
# Push localhost/acme-analytics:<tag> to oci-apps, sign it by digest with the CI
# cosign key (no public transparency log), and verify the signature.
# The host addresses the registry as localhost:30444 (Caddy issues a
# DNS:localhost certificate from the same internal CA).
# Env: TAG (1.0.0)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
TAG="${TAG:-1.0.0}"
REG="localhost:${HTTPS_PORT}"; REF="$REG/oci-apps/acme-analytics"
CERTS="$OUT/certs.d/$REG"; KEYS="$ROOT/signing/keys"
W="$HERE/.work"; mkdir -p "$W/docker"
cp "$TOKENS/ci-podman.json" "$W/docker/config.json"; chmod 600 "$W/docker/config.json"
cat /etc/pki/tls/certs/ca-bundle.crt "$CA" > "$W/ca-bundle.crt" 2>/dev/null || cat "$CA" > "$W/ca-bundle.crt"
podman push --cert-dir "$CERTS" --authfile "$TOKENS/ci-podman.json" --digestfile "$W/digest" \
  "localhost/acme-analytics:$TAG" "docker://$REF:$TAG"
digest=$(<"$W/digest")
echo "push: $REF:$TAG@$digest"
export DOCKER_CONFIG="$W/docker" SSL_CERT_FILE="$W/ca-bundle.crt"
COSIGN_PASSWORD="$(<"$KEYS/cosign.password")" cosign sign --key "$KEYS/cosign.key" \
  --use-signing-config=false --tlog-upload=false --yes "$REF@$digest" 2>&1 | grep -v '^WARNING' || true
cosign verify --key "$KEYS/cosign.pub" --insecure-ignore-tlog "$REF@$digest" 2>/dev/null \
  | jq -c '.[] | .critical | {identity: .identity."docker-reference", digest: .image."docker-manifest-digest"}'
echo "$REF@$digest" > "$W/pushed-ref"
