#!/usr/bin/env bash
# Build localhost/acme-analytics:<tag> from image/Containerfile.
#   - base images are pulled by the host's podman from the registry
#     (localhost:30444/oci-ghcr/..., localhost:30444/oci-redhat/...) with the CA
#     in --cert-dir and the consumer token in --authfile;
#   - RUN steps join NETWORK (default ak-conda-net; build-isolated proves that only
#     the registry is reachable), where ak.internal is Caddy's alias;
#   - the consumer token is passed as a build secret (never in a layer).
# Env: PROJECT (project | project-direct), NETWORK, TAG (default 1.0.0), NO_CACHE=1, EXTRA_BUILD_ARGS
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
TAG="${TAG:-1.0.0}"
mkdir -p "$HERE/.work"
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
cp "$ROOT/signing/keys/cosign.pub" "$HERE/.work/conda-ci-cosign.pub"
args=(--network "${NETWORK:-$NET}"
      --cert-dir "$OUT/certs.d/localhost:${HTTPS_PORT}" --authfile "$TOKENS/consumer-podman.json"
      --secret "id=rattler-auth,src=$TOKENS/consumer-auth.json"
      --build-arg "PROJECT=${PROJECT:-project}"
      -f "$HERE/Containerfile" -t "localhost/acme-analytics:$TAG")
[[ "${NO_CACHE:-0}" == 1 ]] && args+=(--no-cache)
# shellcheck disable=SC2206
args+=(${EXTRA_BUILD_ARGS:-})
echo "+ podman build ${args[*]} $ROOT"
podman build "${args[@]}" "$ROOT"
