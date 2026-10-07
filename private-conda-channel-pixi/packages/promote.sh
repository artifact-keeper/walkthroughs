#!/usr/bin/env bash
# Promote packages from conda-staging to conda-internal through the release gate
# (scan policy conda-release-gate on conda-staging). Prints the gate decision and
# every policy violation for each package. Never skips the policy check unless
# SKIP_POLICY=1 (used only to seed the demo before attestations can verify; the
# promotion record then says so).
#
# Usage: packages/promote.sh [name-or-filename-substring...]   (default: all in staging)
# Exit:  1 if any package was refused
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
U=$(AK_HOST_URL)
JWT=$(admin_token)
filters=("$@"); rc=0
skip=false; [[ "${SKIP_POLICY:-0}" == 1 ]] && skip=true
akcurl -fsS -H "Authorization: Bearer $JWT" "$U/api/v1/repositories/conda-staging/artifacts?per_page=200" \
  | jq -r '.items[] | "\(.id) \(.path)"' | sort -k2 | while read -r id path; do
  if ((${#filters[@]})); then m=0; for f in "${filters[@]}"; do [[ "$path" == *"$f"* ]] && m=1; done; ((m)) || continue; fi
  resp=$(akcurl -sS -X POST -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
    -d "$(jq -nc --argjson s $skip '{target_repository:"conda-internal",skip_policy_check:$s,notes:"walkthrough promotion"}')" \
    -w '\n%{http_code}' "$U/api/v1/promotion/repositories/conda-staging/artifacts/$id/promote")
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  promoted=$(jq -r '.promoted // false' <<<"$body" 2>/dev/null || echo false)
  echo "promote: $path -> conda-internal: HTTP $code promoted=$promoted"
  jq -r '(.policy_violations // [])[] | "    violation [\(.severity)] \(.rule): \(.message)"' <<<"$body" 2>/dev/null || echo "    $body"
  jq -r 'select(.message != null) | "    message: \(.message)"' <<<"$body" 2>/dev/null || true
  [[ "$promoted" == true ]] || rc=1
  echo "$rc" > "${TMPDIR:-/tmp}/ak-promote-rc.$$"
done
rc=$(cat "${TMPDIR:-/tmp}/ak-promote-rc.$$" 2>/dev/null || echo 0); rm -f "${TMPDIR:-/tmp}/ak-promote-rc.$$"
exit "$rc"
