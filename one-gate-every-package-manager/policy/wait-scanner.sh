#!/usr/bin/env bash
# The first scans wait for the bundled scanner's vulnerability database. Until it is ready
# a fail-closed pull is refused and a record-only pull is served pending without a verdict,
# so wait here on a small file that has no advisories: pull it through go-proxy until the
# proxy-scan record for it reads `clean`.
#
#   policy/wait-scanner.sh        (SCANNER_TIMEOUT, default 900 s)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
path='golang.org/x/text/@v/v0.21.0.zip'
deadline=$((SECONDS + ${SCANNER_TIMEOUT:-900}))
echo -n "policy: waiting for the scanner ($path) "
while :; do
  akcurl -sS -o /dev/null "$U/go/go-proxy/$path" || true
  state=$(body_of "$(api GET '/repositories/go-proxy/security/proxy-scans?per_page=500')" | jq -r --arg p "$path" '.items[] | select(.path==$p) | .state' | head -1)
  [[ $state == clean || $state == vulnerable ]] && break
  if (( SECONDS > deadline )); then
    echo; echo "policy: no verdict for $path within ${SCANNER_TIMEOUT:-900}s (state: ${state:-none}); check podman logs ak-gate-backend" >&2
    exit 1
  fi
  echo -n "."; sleep 10
done
echo " ready ($state)"
