#!/usr/bin/env bash
# Build the acme-* conda packages with rattler-build, inside the pixi client
# container on ak-conda-net. rattler-build itself (pixi exec) and every build
# dependency (python, pip, setuptools, the C toolchain, ...) come through the
# registry: /etc/rattler/config.toml mirrors conda-forge to
# https://ak.internal/conda/conda-forge and the consumer token is the only
# credential (RATTLER_AUTH_FILE, read only).
#
# Usage: packages/build.sh [recipe-name...]   (default: all recipes)
# Env:   ACME_CORE_VERSION (default 1.0.0), NETWORK (default ak-conda-net)
# Output: packages/out/{noarch,linux-64}/*.conda
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
RATTLER_BUILD_VERSION="${RATTLER_BUILD_VERSION:-0.76.1}"
mkdir -p "$HERE/out"
recipes=("$@")
if ((${#recipes[@]} == 0)); then args=(--recipe-dir /recipes); else
  args=(); for r in "${recipes[@]}"; do args+=(--recipe "/recipes/$r/recipe.yaml"); done; fi
set -x
podman run --rm --network "${NETWORK:-$NET}" \
  -v ak-conda-pixi-cache:/cache \
  -v "$HERE/recipes:/recipes:ro,z" \
  -v "$HERE/out:/out:z" \
  -v "$TOKENS/consumer-auth.json:/run/secrets/rattler-auth.json:ro,z" \
  -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
  -e ACME_CORE_VERSION="${ACME_CORE_VERSION:-1.0.0}" \
  localhost/ak-conda/pixi-client:0.81.0 \
  pixi exec --spec "rattler-build==$RATTLER_BUILD_VERSION" -- \
    rattler-build build "${args[@]}" --output-dir /out -c conda-forge \
      --skip-existing=local --log-style plain
