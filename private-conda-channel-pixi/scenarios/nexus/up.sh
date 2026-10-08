#!/usr/bin/env bash
# Start scn-nexus (compose project ak-scn-nexus) on ak-conda-net and wait for it.
# Prints the time to first healthy (status endpoint answering).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
t0=$SECONDS
podman compose -p ak-scn-nexus -f "$SCN_DIR/compose.nexus.yml" up -d
w=$(wait_http "http://127.0.0.1:${NEXUS_PORT:-30481}/service/rest/v1/status/writable" 600)
log "scn-nexus writable after $((SECONDS - t0)) s (compose up included)"
