#!/usr/bin/env bash
# Version policies on the public-facing repositories (idempotent):
#   - age gate: a version younger than MIN_AGE_DAYS (7) is left out of the index, and a
#     request for it is held for review (451). Remotes only; the virtuals apply each member's gate.
#   - scan-on-proxy: every file fetched from upstream is scanned (Grype) before it is served;
#     high or critical findings refuse it (403 scan_blocked), an inconclusive scan refuses it
#     too (fail_closed, 423 scan_pending).
# Names are governed separately by policies/curation.sh (the approved list).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
MIN_AGE_DAYS="${MIN_AGE_DAYS:-7}"

for k in "${REMOTES[@]}"; do
  r=$(api PUT "/repositories/$k/age-gate" -d "$(jq -nc --argjson d "$MIN_AGE_DAYS" '{enabled:true,min_age_days:$d,mode:"upstream_publish_time"}')")
  must "age gate on $k" "$r"
  echo "policies: age gate $k: $(body_of "$r" | jq -c '{enabled,min_age_days,mode}')"
done
for k in "${REMOTES[@]}" "${VIRTUALS[@]}"; do
  r=$(api PUT "/repositories/$k/security" -d '{"scan_enabled":true,"scan_on_proxy":true,"proxy_scan_action":"fail_closed",
        "block_on_policy_violation":true,"severity_threshold":"high"}')
  must "scan-on-proxy on $k" "$r"
  echo "policies: scan-on-proxy $k: $(body_of "$r" | jq -c '{scan_on_proxy,proxy_scan_action,severity_threshold}' 2>/dev/null || echo ok)"
done
