#!/usr/bin/env bash
# Trigger the registry's hosted security scan for every artifact in a repository
# (default conda-staging) and wait until each has a completed scan. Prints the
# scan status and finding counts per artifact.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
REPO="${1:-conda-staging}"
U=$(AK_HOST_URL)
JWT=$(admin_token)
A=(-H "Authorization: Bearer $JWT" -H 'Content-Type: application/json')
mapfile -t arts < <(akcurl -fsS "${A[@]}" "$U/api/v1/repositories/$REPO/artifacts?per_page=200" | jq -r '.items[] | "\(.id) \(.path)"')
for a in "${arts[@]}"; do
  id=${a%% *}
  n=$(akcurl -fsS "${A[@]}" "$U/api/v1/security/artifacts/$id/scans" | jq '[(.items // .)[] | select(.status=="completed")] | length')
  if [[ "$n" == 0 ]]; then
    akcurl -sS "${A[@]}" -X POST -d "$(jq -nc --arg id "$id" '{artifact_id:$id}')" "$U/api/v1/security/scan" -o /dev/null -w "scan: triggered ${a#* } HTTP %{http_code}\n"
  fi
done
for a in "${arts[@]}"; do
  id=${a%% *}
  for _ in $(seq 60); do
    s=$(akcurl -fsS "${A[@]}" "$U/api/v1/security/artifacts/$id/scans" | jq -c '[(.items // .)[] | {scan_type,status,findings_count,critical_count,high_count,error_message}]')
    jq -e 'length > 0 and all(.[]; .status != "running" and .status != "pending" and .status != "queued")' <<<"$s" >/dev/null 2>&1 && break
    sleep 5
  done
  echo "scan: ${a#* }: $s"
done
