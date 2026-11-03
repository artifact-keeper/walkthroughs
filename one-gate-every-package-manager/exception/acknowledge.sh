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
# Every completed scan of the artifact: the gate counts unacknowledged rows from all of them
# (Grype and the registry's own dependency scan both wrote rows for this upload).
n=0
for sid in $(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -r '(.items // .)[] | select(.status=="completed") | .id'); do
  for f in $(body_of "$(api GET "/security/scans/$sid/findings?per_page=100")" | jq -r '(.items // .)[] | select(.is_acknowledged==false) | .id'); do
    r=$(api POST "/security/findings/$f/acknowledge" -d "$(jq -nc --arg r "$reason" '{reason:$r}')"); must "acknowledge $f" "$r"
    echo "acknowledge: $(body_of "$r" | jq -r '"\(.source) \(.cve_id) acknowledged by \(.acknowledged_by) at \(.acknowledged_at)"')"
    n=$((n + 1))
  done
done
echo "acknowledge: $n finding(s) acknowledged with reason: $reason"
echo "acknowledge: quarantine: $(body_of "$(api GET "/quarantine/$art")" | jq -c '{quarantine_status, quarantine_source, quarantine_reason}' 2>/dev/null)"
echo "acknowledge: download through npm-internal: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")"
