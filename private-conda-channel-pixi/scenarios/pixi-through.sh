#!/usr/bin/env bash
# Run pixi for a project with a scenario product as the only conda source:
# the walkthrough's client image with scenarios/<product>/pixi-config.toml as
# /etc/pixi/config.toml. PyPI still goes to ak.internal (the products' conda
# repositories are the subject here).
# Usage: scenarios/pixi-through.sh nexus|proget PROJECT_DIR pixi-args...
# Env: PIXI_CONFIG (default scenarios/<product>/pixi-config.toml), CACHE_VOLUME (default scn-<product>-pixi-cache), NETWORK (default ak-conda-net)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P=$1 DIR=$(cd "$2" && pwd); shift 2
exec podman run --rm --network "${NETWORK:-$NET}" \
  -v "${CACHE_VOLUME:-scn-$P-pixi-cache}:/cache" \
  -v "$DIR:/work:z" -w /work \
  -v "${PIXI_CONFIG:-$SCN_DIR/$P/pixi-config.toml}:/etc/pixi/config.toml:ro,z" \
  -v "$TOKENS/consumer-auth.json:/run/secrets/rattler-auth.json:ro,z" \
  -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
  localhost/ak-conda/pixi-client:0.81.0 pixi "$@"
