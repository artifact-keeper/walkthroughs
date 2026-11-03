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
# Any PUT .../security by an instance administrator also LOCKS the policy (#4363) unless the
# body says "instance_locked": false; this script keeps the lock as it is (LOCK=keep), or
# sets it with LOCK=on|off. policy/lock.sh is the explicit form.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mode=${1:?usage: policy/mode.sh record_only|fail_open|fail_closed|off [REPO...]}; shift
repos=("$@"); [[ ${#repos[@]} -gt 0 ]] || repos=("${REMOTES[@]}")
LOCK="${LOCK:-keep}"
case $mode in
  record_only|fail_open|fail_closed)
    body=$(jq -nc --arg a "$mode" --arg t "$THRESHOLD" \
      '{scan_enabled:true,scan_on_proxy:true,proxy_scan_action:$a,block_on_policy_violation:true,severity_threshold:$t}') ;;
  off) body='{"scan_on_proxy":false}' ;;
  *) echo "mode.sh: unknown mode '$mode'" >&2; exit 2 ;;
esac
for k in "${repos[@]}"; do
  case $LOCK in
    on)   b=$(jq -c '. + {instance_locked:true}' <<<"$body") ;;
    off)  b=$(jq -c '. + {instance_locked:false}' <<<"$body") ;;
    keep) cur=$(body_of "$(api GET "/repositories/$k/security")" | jq -r '.config.instance_locked // false')
          b=$(jq -c --argjson l "$cur" '. + {instance_locked:$l}' <<<"$body") ;;
    *) echo "mode.sh: LOCK=on|off|keep" >&2; exit 2 ;;
  esac
  r=$(api PUT "/repositories/$k/security" -d "$b"); must "scan config on $k" "$r"
  echo "policy: $k $(body_of "$r" | jq -c '{scan_on_proxy,proxy_scan_action,block_on_policy_violation,severity_threshold,instance_locked}')"
done
