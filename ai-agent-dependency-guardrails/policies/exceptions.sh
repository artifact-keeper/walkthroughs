#!/usr/bin/env bash
# Apply the reviewed cooldown exceptions in policies/exceptions.txt (idempotent).
# For each entry: request the version from its remote; a 451 age_gate_blocked answer carries
# the review id, which is approved with the reason from the file. 200 means the version is
# old enough already and nothing is approved. A version that does not exist, or that the
# scan refuses (scan_blocked), stops the run with what to do.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
HINT="re-lock with make lock or add an exception (policies/exceptions.txt) for another version"
fail() { echo "exceptions: $*" >&2; exit 1; }
fetch() { # fetch URL -> sets code, and body unless the answer is 200 (the file itself)
  local t; t=$(mktemp)
  code=$(akcurl -sS -H "Authorization: Bearer $ADMIN" -o "$t" -w '%{http_code}' "$1" || true)
  body=""; [[ $code == 200 ]] || body=$(head -c 2000 "$t"); rm -f "$t"
}
grep -vE '^\s*(#|$)' "$here/exceptions.txt" | while read -r fmt name version reason; do
  case $fmt in
    npm)  url="$U/npm/npm-remote/$name/-/${name##*/}-$version.tgz" ;;
    pypi) url=$(akcurl -sS -H "Authorization: Bearer $ADMIN" -H 'Accept: application/vnd.pypi.simple.v1+json' \
                  "$U/pypi/pypi-remote/simple/$name/" | jq -r --arg v "$version" \
                  '[.files[]? | select(.filename | contains("-" + $v + "-") or endswith("-" + $v + ".tar.gz"))][0].url // empty') || true
          [[ -n $url ]] || fail "$fmt $name $version: no such version on pypi-remote; $HINT" ;;
    *) fail "unknown format $fmt" ;;
  esac
  fetch "$url"
  case $code in
    200) echo "exceptions: $fmt $name $version is served (old enough or already approved)"; continue ;;
    404) fail "$fmt $name $version: no such version upstream (HTTP 404); $HINT" ;;
  esac
  [[ $body == *scan_blocked* ]] && fail "$fmt $name $version is refused by the scan (scan_blocked): $HINT"
  rid=$(jq -r '.review_id // empty' <<<"$body" 2>/dev/null || true)
  [[ -n $rid ]] || fail "$fmt $name $version: HTTP $code, no review id: $body"
  rr=$(api POST "/admin/age-gate/reviews/$rid/approve" -d "$(jq -nc --arg r "$reason" '{reason:$r}')"); must "approve $name $version" "$rr"
  echo "exceptions: approved $fmt $name $version (review $rid): $reason"
  # The approved version is scanned on its first download; check it now rather than at install.
  fetch "$url"
  [[ $code == 200 ]] && continue
  [[ $body == *scan_blocked* ]] && fail "$fmt $name $version is refused by the scan (scan_blocked): $HINT"
  [[ $code == 404 ]] && fail "$fmt $name $version: no such version upstream (HTTP 404); $HINT"
  fail "$fmt $name $version: HTTP $code after approval: $body"
done
