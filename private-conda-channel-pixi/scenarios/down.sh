#!/usr/bin/env bash
# make scenarios-down: stop and remove scn-nexus and scn-fake-forge (compose project ak-scn-nexus).
# The Nexus volume scn-nexus-data is kept (podman volume rm scn-nexus-data wipes it). Artifact
# Keeper's scn-* repositories are left in place; the ak-conda stack is not touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
podman compose -p ak-scn-nexus -f "$SCN_DIR/compose.nexus.yml" down 2>&1 | tail -3
podman rm -f scn-fake-forge >/dev/null 2>&1 || true
log "scenario overlay down (volume scn-nexus-data kept)"
