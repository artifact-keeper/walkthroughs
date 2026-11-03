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
if body_of "$(api GET '/repositories/npm-internal/artifacts?per_page=100')" | jq -e '(.items // .)[] | select(.path | endswith("lodash-4.17.15.tgz"))' >/dev/null; then
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
  # The list also holds a not-applicable OpenSCAP row; the verdict is the latest Grype scan.
  scan=$(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -c '[(.items // .)[] | select(.scan_type=="grype")] | sort_by(.created_at) | reverse | .[0] // empty')
  st=$(jq -r '.status // empty' <<<"$scan")
  [[ $st == completed || $st == failed ]] && break
  echo -n "."; sleep 5
done
echo " $st"
sid=$(jq -r .id <<<"$scan")
echo "vendor: scan $sid: $(jq -c '{scan_type, status, grade_status, findings_count, critical_count, high_count, vuln_db_version}' <<<"$scan")"
# Every scanner that ran on the upload: Grype and the registry's own dependency scan both
# write findings, and the gate counts all of them.
body_of "$(api GET "/security/artifacts/$art/scans")" | jq -r '(.items // .)[] | select(.status=="completed") | "\(.scan_type)\t\(.id)\t\(.findings_count) findings\tgrade_status=\(.grade_status)"' | column -t -s $'\t'
for s in $(body_of "$(api GET "/security/artifacts/$art/scans")" | jq -r '(.items // .)[] | select(.status=="completed") | .id'); do
  body_of "$(api GET "/security/scans/$s/findings?per_page=100")" | jq -r '(.items // .)[] | "  \(.source)\t\(.severity)\t\(.cve_id)\t\(.affected_component)@\(.affected_version)\tfixed=\(.fixed_version)\tacknowledged=\(.is_acknowledged)"'
done | column -t -s $'\t' | tee "$ROOT/out/vendored-findings.txt"
echo "vendor: download through npm-internal: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")"
