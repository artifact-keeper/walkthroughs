#!/usr/bin/env bash
# Run a pixi command for this project inside the pixi client container on
# ak-conda-net (or NETWORK=build-isolated), with the consumer token as
# RATTLER_AUTH_FILE. Example: project/pixi-run.sh lock
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
AUTH="${AUTH_FILE:-$TOKENS/consumer-auth.json}"
exec podman run --rm ${TTY:+-t} --network "${NETWORK:-$NET}" \
  -v "${CACHE_VOLUME:-ak-conda-pixi-cache}:/cache" \
  -v "$HERE:/work:z" -w /work \
  -v "$AUTH:/run/secrets/rattler-auth.json:ro,z" \
  -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
  ${EXTRA_PODMAN_ARGS:-} \
  localhost/ak-conda/pixi-client:0.81.0 pixi "$@"
