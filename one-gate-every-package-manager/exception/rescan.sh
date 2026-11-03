#!/usr/bin/env bash
# What happens to the acknowledgement when the package is scanned again (a forced rescan
# here; a scanner database update does the same). Issue #5153: acknowledgement is stored
# on the finding row, a rescan writes new rows, and the gate counts every unacknowledged
# row the artifact ever had, so the download is refused again.
#
#   exception/rescan.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../policy/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
art=$(cat "$ROOT/out/vendored-artifact-id")
before=$(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -c '[(.items // .)[] | select(.scan_type=="grype")] | sort_by(.created_at) | reverse | .[0] // empty' | jq -r .id)
r=$(api POST /security/scan -d "$(jq -nc --arg a "$art" '{artifact_id:$a, bypass_dedup:true}')"); must "rescan" "$r"
echo "rescan: $(body_of "$r" | jq -c .)"
echo -n "rescan: waiting for a new completed scan "
for _ in $(seq 60); do
  scan=$(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -c --arg b "$before" '[(.items // .)[] | select(.scan_type=="grype" and .id != $b and .status=="completed")] | sort_by(.created_at) | reverse | .[0] // empty')
  [[ -n $scan ]] && break
  echo -n "."; sleep 5
done
echo
[[ -n $scan ]] || { echo "rescan: no new completed scan" >&2; exit 1; }
sid=$(jq -r .id <<<"$scan")
echo "rescan: new scan $sid: $(jq -c '{status, findings_count, acknowledged_count}' <<<"$scan")"
body_of "$(api GET "/security/scans/$sid/findings?per_page=100")" | jq -r '(.items // .)[] | "  \(.severity)\t\(.cve_id)\t\(.package_name // .package)@\(.package_version // .version)\tacknowledged=\(.is_acknowledged)"' | column -t -s $'\t'
echo "rescan: download through npm-internal: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")"
