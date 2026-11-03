#!/usr/bin/env bash
# Set the proxy scan gate on the five proxies (or the repositories given), idempotently:
#
#   policy/mode.sh record_only|fail_open|fail_closed|off [REPO...]
#
# Every mode scans each proxied file and records the verdict; they differ in what is
# withheld (docs/security/scan-on-proxy.md in artifact-keeper):
#   record_only   nothing: a vulnerable file is served with X-AK-Scan: recorded
#   fail_open     a known-vulnerable file (403); a first pull is served while it is scanned
#   fail_closed   a known-vulnerable file (403) and anything inconclusive (423): a file is
#                 never served before a verdict exists
#   off           scan_on_proxy false (the setting is kept, the gate does not run)
# The severity gate is THRESHOLD (default high): findings at or above it block.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mode=${1:?usage: policy/mode.sh record_only|fail_open|fail_closed|off [REPO...]}; shift
repos=("$@"); [[ ${#repos[@]} -gt 0 ]] || repos=("${REMOTES[@]}")
case $mode in
  record_only|fail_open|fail_closed)
    body=$(jq -nc --arg a "$mode" --arg t "$THRESHOLD" \
      '{scan_enabled:true,scan_on_proxy:true,proxy_scan_action:$a,block_on_policy_violation:true,severity_threshold:$t}') ;;
  off) body='{"scan_on_proxy":false}' ;;
  *) echo "mode.sh: unknown mode '$mode'" >&2; exit 2 ;;
esac
for k in "${repos[@]}"; do
  r=$(api PUT "/repositories/$k/security" -d "$body"); must "scan config on $k" "$r"
  echo "policy: $k $(body_of "$r" | jq -c '{scan_on_proxy,proxy_scan_action,block_on_policy_violation,severity_threshold,instance_locked}')"
done
