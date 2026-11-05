#!/usr/bin/env bash
# Build localhost/ak-mcp/workstation:latest from client/Containerfile with the pins in
# client/VERSIONS, and print the versions it holds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
# shellcheck source=/dev/null
source <(grep -E '^[A-Z0-9_]+=' "$HERE/VERSIONS")
mkdir -p "$HERE/.work"
[[ -s "$CA" ]] || { echo "client/build.sh: $CA missing; run make registry-up first" >&2; exit 1; }
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
podman build --build-arg "NODE_IMAGE=$NODE_IMAGE" --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" \
  --build-arg "MCP_PUBLISHER_VERSION=$MCP_PUBLISHER_VERSION" \
  --build-arg "MCP_PUBLISHER_SHA256_AMD64=$MCP_PUBLISHER_SHA256_AMD64" \
  --build-arg "MCP_PUBLISHER_SHA256_ARM64=$MCP_PUBLISHER_SHA256_ARM64" \
  -t localhost/ak-mcp/workstation:latest -f "$HERE/Containerfile" "$HERE"
echo "client: versions in localhost/ak-mcp/workstation:latest"
podman run --rm localhost/ak-mcp/workstation:latest sh -c '
  echo "node           $(node --version)"
  echo "npm            $(npm --version)"
  echo "claude         $(claude --version)"
  echo "skopeo         $(skopeo --version)"
  echo "mcp-publisher  $(mcp-publisher --version 2>&1 | head -1)"' | tee "$HERE/.work/versions.txt"
