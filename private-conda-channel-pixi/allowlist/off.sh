#!/usr/bin/env bash
# Turn the virtual channel's allowlist off: the full merge (every conda-forge
# record) comes back. Default: keep the entries and set enabled=false;
# --delete removes the list. Idempotent.
# Usage: allowlist/off.sh [--delete]   (env REPO, default conda-virtual)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [[ "${1:-}" == --delete ]]; then
  r=$(api DELETE)
  [[ $(code_of "$r") =~ ^(200|204|404)$ ]] || { echo "off.sh: DELETE $REPO/allowlist: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
  log "DELETE /api/v1/repositories/$REPO/allowlist -> HTTP $(code_of "$r")"; exit 0
fi
r=$(api GET); entries='[]'
[[ $(code_of "$r") == 200 ]] && entries=$(body_of "$r" | jq -c '.entries // []')
r=$(api PUT -d "$(jq -nc --argjson e "$entries" '{enabled: false, entries: $e}')")
[[ $(code_of "$r") == 200 ]] || { echo "off.sh: PUT $REPO/allowlist: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
log "PUT /api/v1/repositories/$REPO/allowlist -> HTTP 200 $(body_of "$r" | jq -c '{enabled, entry_count}')"
