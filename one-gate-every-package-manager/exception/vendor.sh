#!/usr/bin/env bash
# The legitimate exception, hosted side. A team still needs lodash 4.17.15 (a legacy
# application pins it; the finding does not apply to how they use it). The gate on
# npm-proxy refuses it, so they vendor it: publish the tarball to npm-internal, where a scan
# policy applies and findings can be acknowledged one by one with a reason.
#
#   exception/vendor.sh        publishes clients/out/lodash-4.17.15.tgz to npm-internal,
#                              waits for the upload scan, shows the findings and the refusal
# The tarball comes from clients/known-bad.sh npm, run while the gate was record-only.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../policy/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; mkdir -p "$ROOT/out"
TGZ="$ROOT/clients/out/lodash-4.17.15.tgz"
[[ -f "$TGZ" ]] || { echo "vendor.sh: $TGZ missing: run clients/known-bad.sh npm while the gate is record-only" >&2; exit 1; }
CI=$(cat "$TOKENS/ci-npm.token")

# npm publish from a container, with the CI token for npm-internal only.
proj=$(mktemp -d); trap 'rm -rf "$proj"' EXIT
cp "$TGZ" "$proj/"
printf 'registry=https://ak.internal/npm/npm-internal/\n//ak.internal/npm/npm-internal/:_authToken=%s\ncafile=/run/ak/ca.crt\nignore-scripts=true\naudit=false\nfund=false\nupdate-notifier=false\ncache=/tmp/npmcache\n' "$CI" > "$proj/.npmrc"
chmod 600 "$proj/.npmrc"
if akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz" | grep -q '^20'; then
  echo "vendor: lodash 4.17.15 is already in npm-internal"
else
  CLIENT_ARGS="-e NPM_CONFIG_USERCONFIG=/work/.npmrc" "$ROOT/clients/run.sh" npm -w "$proj" -- npm publish lodash-4.17.15.tgz --loglevel http 2>&1 | grep -vE '^npm (http|verb)' || true
fi

# The artifact and its upload scan.
art=$(body_of "$(api GET '/repositories/npm-internal/artifacts?per_page=100')" | jq -r '(.items // .)[] | select(.path | endswith("lodash-4.17.15.tgz")) | .id' | head -1)
[[ -n "$art" ]] || { echo "vendor.sh: lodash-4.17.15.tgz not found in npm-internal" >&2; exit 1; }
echo "$art" > "$ROOT/out/vendored-artifact-id"
echo -n "vendor: waiting for the upload scan of $art "
for _ in $(seq 60); do
  scan=$(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -c '(.items // .)[0] // empty')
  st=$(jq -r '.status // empty' <<<"$scan")
  [[ $st == completed || $st == failed ]] && break
  echo -n "."; sleep 5
done
echo " $st"
sid=$(jq -r .id <<<"$scan")
echo "vendor: scan $sid: $(jq -c '{status, scanner_type, grade_status, findings_count, critical_count, high_count}' <<<"$scan")"
body_of "$(api GET "/security/scans/$sid/findings?per_page=100")" | jq -r '(.items // .)[] | "  \(.severity)\t\(.cve_id)\t\(.package_name // .package)@\(.package_version // .version)\tacknowledged=\(.is_acknowledged)"' | column -t -s $'\t' | tee "$ROOT/out/vendored-findings.txt"
echo "vendor: download through npm-internal: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")"
