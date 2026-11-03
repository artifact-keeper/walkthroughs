#!/usr/bin/env bash
# Hold the proxy scan policy of the five proxies centrally (#4363): while locked, a
# repository administrator can tighten the policy but cannot weaken it (turn the gate off,
# move towards record_only, raise the threshold). Only an instance administrator can.
#
#   policy/lock.sh on|off [REPO...]
#
# Any PUT .../security by an instance administrator locks the policy unless the body says
# "instance_locked": false, so the PUT below carries the flag explicitly either way.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
state=${1:?usage: policy/lock.sh on|off [REPO...]}; shift
repos=("$@"); [[ ${#repos[@]} -gt 0 ]] || repos=("${REMOTES[@]}")
case $state in on) v=true ;; off) v=false ;; *) echo "lock.sh: on|off" >&2; exit 2 ;; esac
for k in "${repos[@]}"; do
  r=$(api PUT "/repositories/$k/security" -d "{\"instance_locked\":$v}"); must "lock on $k" "$r"
  echo "policy: $k $(body_of "$r" | jq -c '{proxy_scan_action,severity_threshold,instance_locked}')"
done
