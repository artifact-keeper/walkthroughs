#!/usr/bin/env bash
# Accept the findings on the vendored package with a recorded reason, then show that the
# download is allowed. Acknowledgement is per finding row and admin-only
# (POST /api/v1/security/findings/{id}/acknowledge).
#
#   exception/acknowledge.sh ["reason"]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../policy/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reason=${1:-"legacy-app: lodash is only used for _.get on trusted config; prototype pollution not reachable; ticket SEC-421"}
art=$(cat "$ROOT/out/vendored-artifact-id")
sid=$(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -c '[(.items // .)[] | select(.scan_type=="grype")] | sort_by(.created_at) | reverse | .[0] // empty' | jq -r .id)
n=0
for f in $(body_of "$(api GET "/security/scans/$sid/findings?per_page=100")" | jq -r '(.items // .)[] | select(.is_acknowledged==false) | .id'); do
  r=$(api POST "/security/findings/$f/acknowledge" -d "$(jq -nc --arg r "$reason" '{reason:$r}')"); must "acknowledge $f" "$r"
  echo "acknowledge: $(body_of "$r" | jq -r '"\(.cve_id) acknowledged by \(.acknowledged_by) at \(.acknowledged_at)"')"
  n=$((n + 1))
done
echo "acknowledge: $n finding(s) acknowledged on scan $sid with reason: $reason"
echo "acknowledge: download through npm-internal: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")"
