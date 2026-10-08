#!/usr/bin/env bash
# Start scn-proget (compose project ak-scn-proget) on ak-conda-net and wait for it.
# Writes .work/proget-ca-bundle.crt (system bundle of the image + the ak.internal CA).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
img=proget.inedo.com/productimages/inedo/proget:${PROGET_VERSION:-26.0.12}
{ podman run --rm --entrypoint cat "$img" /etc/ssl/certs/ca-certificates.crt; cat "$CA"; } > "$WORK/proget-ca-bundle.crt"
t0=$SECONDS
podman compose -p ak-scn-proget -f "$SCN_DIR/compose.proget.yml" up -d
w=$(wait_http "http://127.0.0.1:${PROGET_PORT:-30482}/health" 600)
log "scn-proget /health 200 after $((SECONDS - t0)) s (compose up included)"
curl -fsS "http://127.0.0.1:${PROGET_PORT:-30482}/health" | jq -c . || true
