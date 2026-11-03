#!/usr/bin/env bash
# The operator's view once the gate enforces: the security dashboard, the cross-repository
# blocked list, the admin hold queues and the refusal audit rows. Raw JSON is saved under
# out/review/ for the lab notes.
#
#   policy/review.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; R="$ROOT/out/review"; mkdir -p "$R"
save() { local name=$1 path=$2 r; r=$(api GET "$path"); must "GET $path" "$r"; body_of "$r" > "$R/$name.json"; echo "$R/$name.json"; }

echo "== GET /api/v1/security/dashboard"
save dashboard /security/dashboard >/dev/null
jq '{repos_with_scanning, total_scans, total_findings, critical_findings, high_findings, policy_violations_blocked, proxy_blocked, repos_rated, repos_incomplete, repos_unrated}' "$R/dashboard.json"

echo "== GET /api/v1/security/proxy-blocked   (instance admin; what every proxy refuses right now)"
save proxy-blocked '/security/proxy-blocked?per_page=100' >/dev/null
jq -r '.items[] | "\(.repository_key)\t\(.max_severity)\t\(.findings_count) findings\t\(.cve_ids[0:3] | join(","))\t\(.path)"' "$R/proxy-blocked.json" | column -t -s $'\t'

echo "== GET /api/v1/admin/holds/summary"
save holds-summary /admin/holds/summary >/dev/null; jq -c . "$R/holds-summary.json"

echo "== GET /api/v1/admin/holds/policy-blocks   (proxy-cache items first, then hosted)"
save policy-blocks '/admin/holds/policy-blocks?per_page=100' >/dev/null
jq -r '.items[] | "\(.kind // .source // "-")\t\(.repository_key)\t\(.max_severity // "-")\t\(.path // .name)"' "$R/policy-blocks.json" | column -t -s $'\t'

echo "== GET /api/v1/security/scores   (grade_status and coverage, 1.12.0)"
save scores /security/scores >/dev/null
jq -r '(if type=="array" then . else (.items // .scores // []) end)[] | "\(.repository_key // .repository_id)\tgrade=\(.grade // "null")\tstatus=\(.grade_status // "-")\tcoverage=\(.coverage // "null" | if type=="object" then "\(.cataloged)/\(.scanned) of \(.artifacts)" else . end)"' "$R/scores.json" | column -t -s $'\t'

echo "== GET /api/v1/admin/audit   (PROXY_SCAN_BLOCKED rows: who asked for what)"
save audit '/admin/audit?per_page=200' >/dev/null
jq -r '(.items // .logs // [])[] | select(.action=="PROXY_SCAN_BLOCKED") | "\(.created_at // .timestamp)\t\(.details.principal // "anonymous")\t\(.ip_address // "-")\t\(.details.repository)\tattempts=\(.details.attempts)\t\(.details.path)"' "$R/audit.json" | column -t -s $'\t'
