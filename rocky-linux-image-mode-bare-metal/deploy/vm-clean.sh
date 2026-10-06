#!/usr/bin/env bash
# Stop the VM and HTTP server and delete deploy/state (disk, vars, logs).
# The pxeboot media cache is kept unless CLEAN_CACHE=1.
source "$(dirname "$0")/lib.sh"
"$DEPLOY_DIR/vm-stop.sh"
"$DEPLOY_DIR/serve-ks.sh" stop >/dev/null 2>&1 || true
rm -rf "$STATE_DIR"
log "removed $STATE_DIR"
if [[ "${CLEAN_CACHE:-0}" == 1 ]]; then rm -rf "$CACHE_DIR"; log "removed $CACHE_DIR"; fi
