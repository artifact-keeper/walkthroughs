#!/usr/bin/env bash
# G2 Publish: rattler-build upload artifactory PUTs to a staging repo with a
# Bearer token (201); a re-upload is 409; a linux-64 package uploaded without a
# subdir header lands in linux-64; a linux-64 package PUT under noarch/ is refused.
# Uses a scratch staging-like repo conda-gate-publish so the demo channels stay clean.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G2; R=conda-gate-publish
ensure_repo $R '{"key":"conda-gate-publish","name":"gate scratch: publish tests","format":"conda","repo_type":"local","visibility":"private"}' || exit 1
# Clean the scratch repo so the gate is re-runnable.
for p in $(akcurl -fsS -H "$(admin_h)" "$U/api/v1/repositories/$R/artifacts?per_page=200" | jq -r '.items[].path'); do
  http DELETE "$U/api/v1/repositories/$R/artifacts/$p" admin >/dev/null; done
FM=$(cd "$ROOT/packages/out" && ls linux-64/acme-fastmath-*.conda | head -1)
CORE=$(cd "$ROOT/packages/out" && ls noarch/acme-core-1.0.0-*.conda | head -1)
c=$(http POST "$U/api/v1/repositories/$R/tokens" admin -H 'Content-Type: application/json' -d '{"name":"gate-publish","scopes":["read:artifacts","write:artifacts"],"expires_in_days":1}')
jq -n --arg h "$AK_HOST" --arg t "$(jq -r .token "$SP_TMP/body")" '{($h):{BearerToken:$t}}' > "$SP_TMP/gate-auth.json"; chmod 600 "$SP_TMP/gate-auth.json"

up() { podman run --rm --network "$NET" -v ak-conda-pixi-cache:/cache -v "$ROOT/packages/out:/out:ro,z" \
        -v "$SP_TMP/gate-auth.json:/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json "$CLIENT" \
        pixi exec --spec rattler-build==0.76.1 -- rattler-build upload artifactory --log-style plain \
        --url "$AK_URL/conda" --channel "$R" "/out/$1" 2>&1 | grep -v '^ WARN'; return "${PIPESTATUS[0]}"; }

t0=$(date +%s)
out=$(up "$CORE"); rc=$?; echo "first upload rc=$rc $out"
access_since "$t0" | grep "PUT" | tee "$SP_TMP/put.tsv"
if [[ $rc == 0 ]] && grep -q $'\t201\t' "$SP_TMP/put.tsv" && grep -q REDACTED "$SP_TMP/put.tsv"; then
  pass $G "rattler-build upload artifactory: PUT /conda/$R/$CORE -> 201 with Authorization"
else fail $G "rattler-build upload artifactory" "rc=$rc $(tail -1 <<<"$out")"; fi
out=$(up "$CORE"); rc=$?; echo "second upload rc=$rc $out"
grep -q '409' <<<"$out" && pass $G "re-upload of the same file -> 409 Conflict" || fail $G "re-upload" "$out"

# POST /conda/<repo>/upload without X-Conda-Subdir, a linux-64 package
c=$(http POST "$U/conda/$R/upload" admin -H "X-Package-Filename: ${FM#linux-64/}" --data-binary "@$ROOT/packages/out/$FM"); echo "POST upload (no subdir header) -> $c $(body | head -c 300)"
where=$(akcurl -fsS -H "$(admin_h)" "$U/api/v1/repositories/$R/artifacts?per_page=200" | jq -r '.items[] | select(.path|test("acme-fastmath")) | .path')
echo "stored as: $where"
if [[ "$where" == linux-64/* ]]; then pass $G "POST without X-Conda-Subdir lands a linux-64 package in linux-64"
else blocked F8 $G "POST without X-Conda-Subdir lands a linux-64 package in linux-64" "stored as '${where:-nothing}' (HTTP $c)"; fi
for p in $where; do http DELETE "$U/api/v1/repositories/$R/artifacts/$p" admin >/dev/null; done

# PUT a linux-64 package under noarch/
c=$(http PUT "$U/conda/$R/noarch/${FM#linux-64/}" admin --data-binary "@$ROOT/packages/out/$FM"); echo "PUT linux-64 package to noarch/ -> $c $(body | head -c 300)"
if [[ "$c" =~ ^4 ]]; then pass $G "a linux-64 package PUT under noarch/ is refused ($c)"
else blocked F8 $G "a linux-64 package PUT under noarch/ is refused" "HTTP $c, accepted and indexed as subdir $(body | jq -r .subdir 2>/dev/null)"; fi
http DELETE "$U/api/v1/repositories/$R/artifacts/noarch/${FM#linux-64/}" admin >/dev/null
