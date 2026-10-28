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

# The first scans wait for the scanner's vulnerability database. Until it is ready a download
# is refused (fail closed), so wait here, on a small file from the lockfile that has no
# advisories, rather than fail the first install.
url=$(python3 -I -c 'import sys, tomllib
for p in tomllib.load(open(sys.argv[1], "rb"))["package"]:
    if p["name"] == "sniffio": print(p["wheels"][0]["url"])' "$(dirname "${BASH_SOURCE[0]}")/../app/uv.lock")
url="$U${url#https://ak.internal}"
deadline=$((SECONDS + ${SCANNER_TIMEOUT:-900}))
echo -n "policies: waiting for the scanner (${url##*/}) "
while code=$(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$url" || true); [[ $code != 200 ]]; do
  if (( SECONDS > deadline )); then
    echo; echo "policies: the scanner did not pass ${url##*/} within ${SCANNER_TIMEOUT:-900}s (last answer HTTP $code);" \
      "check podman logs ak-agent-backend (vulnerability database download?)" >&2
    exit 1
  fi
  echo -n "."; sleep 10
done
echo " ready"
