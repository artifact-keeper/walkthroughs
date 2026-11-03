#!/usr/bin/env bash
# Delete everything this walkthrough created (make clean): the ak-gate-* containers, the
# ak-gate_* volumes, the network, plus the generated secrets, tokens and local state.
# Missing pieces are skipped; any other error stops the script. The client base images
# and the images of the stack itself are kept.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
ROOT="$here/.."
if [[ -f "$ENV_FILE" ]]; then load_env; compose --profile scanners down --volumes --remove-orphans; fi
ids=$(podman ps -aq --filter name='^ak-gate-')
[[ -z $ids ]] || podman rm -f $ids >/dev/null
vols=$(podman volume ls -q --filter name='^ak-gate_')
[[ -z $vols ]] || podman volume rm -f $vols >/dev/null
if podman network exists "$NET"; then podman network rm -f "$NET" >/dev/null; fi
rm -rf "$ENV_FILE" "$TOKENS" "$OUT" "$ROOT/out" "$ROOT/clients/out"
echo "clean: removed containers, volumes, the network, and local state"
