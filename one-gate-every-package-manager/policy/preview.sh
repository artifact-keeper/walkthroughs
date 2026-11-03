#!/usr/bin/env bash
# What would be blocked: for each proxy, the files whose recorded verdict is vulnerable at
# or above the threshold. Under record_only these are served (X-AK-Scan: recorded) and
# appear in no "blocked" list, because nothing is blocked yet; this script reads the
# per-repository proxy-scan records instead, which every mode writes.
#
#   policy/preview.sh [REPO...]        table on stdout, JSON in out/preview.json
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; mkdir -p "$ROOT/out"
repos=("$@"); [[ ${#repos[@]} -gt 0 ]] || repos=("${REMOTES[@]}")
rank=$(sev_rank "$THRESHOLD")
: > "$ROOT/out/preview.json"
printf '%-13s %-9s %-11s %-9s %-10s %s\n' REPOSITORY STATE SEVERITY FINDINGS CATALOGED PATH
for k in "${repos[@]}"; do
  r=$(api GET "/repositories/$k/security/proxy-scans?per_page=500"); must "proxy-scans of $k" "$r"
  body_of "$r" | jq -c --arg k "$k" '.items[] | {repository:$k, path, state, max_severity, findings_count, components_cataloged, digest, scanned_at, not_scanned_reason}' >> "$ROOT/out/preview.json"
  body_of "$r" | jq -r --arg k "$k" '.summary // {} | "\($k): \(.clean // 0) clean, \(.vulnerable // 0) vulnerable, \(.not_scanned // 0) not scanned, \(.total_digests // 0) digests"' >&2
done
would=0
while IFS=$'\t' read -r k path state sev n cat; do
  mark=" "
  if [[ $state == vulnerable ]] && (( $(sev_rank "$sev") >= rank )); then mark="*"; would=$((would + 1)); fi
  printf '%s%-12s %-9s %-11s %-9s %-10s %s\n' "$mark" "$k" "$state" "${sev:--}" "${n:--}" "${cat:--}" "$path"
done < <(jq -r '[.repository, .path, .state, (.max_severity // ""), (.findings_count // ""), (.components_cataloged // "")] | @tsv' "$ROOT/out/preview.json" | sort)
echo "* = would be refused with the gate enforcing at threshold '$THRESHOLD': $would file(s)"
