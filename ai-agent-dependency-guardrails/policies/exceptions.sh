#!/usr/bin/env bash
# Apply the reviewed cooldown exceptions in policies/exceptions.txt (idempotent).
# For each entry: request the version from its remote; a 451 age_gate_blocked answer carries
# the review id, which is approved with the reason from the file. 200 means the version is
# old enough already and nothing is approved.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
grep -vE '^\s*(#|$)' "$here/exceptions.txt" | while read -r fmt name version reason; do
  case $fmt in
    npm)  url="$U/npm/npm-remote/$name/-/${name##*/}-$version.tgz" ;;
    pypi) url=$(akcurl -fsS -H "Authorization: Bearer $ADMIN" -H 'Accept: application/vnd.pypi.simple.v1+json' \
                  "$U/pypi/pypi-remote/simple/$name/" | jq -r --arg v "$version" '[.files[] | select(.filename | contains("-" + $v + "-") or endswith("-" + $v + ".tar.gz"))][0].url') ;;
    *) echo "exceptions: unknown format $fmt" >&2; exit 1 ;;
  esac
  r=$(akcurl -sS -H "Authorization: Bearer $ADMIN" -o /dev/null -w '%{http_code}' "$url" || true)
  if [[ $r == 200 ]]; then echo "exceptions: $fmt $name $version is served (old enough or already approved)"; continue; fi
  body=$(akcurl -sS -H "Authorization: Bearer $ADMIN" "$url")
  rid=$(jq -r '.review_id // empty' <<<"$body")
  [[ -n $rid ]] || { echo "exceptions: $fmt $name $version: HTTP $r, no review id: $body" >&2; exit 1; }
  rr=$(api POST "/admin/age-gate/reviews/$rid/approve" -d "$(jq -nc --arg r "$reason" '{reason:$r}')"); must "approve $name $version" "$rr"
  echo "exceptions: approved $fmt $name $version (review $rid): $reason"
done
