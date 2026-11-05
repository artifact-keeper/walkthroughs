#!/usr/bin/env bash
# Build localhost/ak-offgrid/agent:latest from agent/Containerfile while seeding. The base
# image is pulled through oci-dockerhub from the host (localhost:30450, developer token).
# Rootless podman cannot attach a build to a named network, so the RUN steps use the host's
# network and reach Caddy as ak.internal:30450 (--add-host); they install from the pypi
# Virtual. Prints the versions it holds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
load_env
# shellcheck source=/dev/null
source <(grep -E '^[A-Z0-9_]+=' "$HERE/VERSIONS")
mkdir -p "$HERE/.work"
[[ -s "$CA" ]] || { echo "agent/build.sh: $CA missing; run make registry-up first" >&2; exit 1; }
[[ -s "$HERE/requirements.lock" ]] || { echo "agent/build.sh: requirements.lock missing; run make lock" >&2; exit 1; }
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
P="localhost:${HTTPS_PORT}"
podman build --network host --add-host "$AK_HOST:127.0.0.1" --build-arg "AK=https://$AK_HOST:$HTTPS_PORT" \
  --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/developer-podman.json" \
  --secret "id=ak_token,src=$TOKENS/developer.token" \
  --build-arg "REG=$P" --build-arg "PYTHON_IMAGE=$PYTHON_IMAGE" \
  --label ak-offgrid=agent -t localhost/ak-offgrid/agent:latest -f "$HERE/Containerfile" "$HERE"
podman run --rm localhost/ak-offgrid/agent:latest python -c '
import importlib.metadata as m
for d in ("openai", "mcp", "huggingface_hub", "mcp-sqlite3", "fastmcp", "acme-inventory-mcp"):
    print(f"{d:20} {m.version(d)}")' | tee "$HERE/.work/versions.txt"
