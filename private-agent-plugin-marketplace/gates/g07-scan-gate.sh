#!/usr/bin/env bash
# G7 Scan gate: in a scratch repository with a block_unscanned scan policy and scanning on
# demand (scan_on_upload off, so the unscanned state lasts as long as the gate needs):
# a scanned 1.0.0 is served; an unscanned 1.1.0 is hidden from every document and
# index.json, and its download is 403; once its scan completes it is listed and downloads.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G7; R=agent-plugins-gate-g7; P=acme-g7
fresh_repo "$R" || exit 1
rid=$(akcurl -fsS -H "$(admin_h)" "$U/api/v1/repositories/$R" | jq -r .id)
c=$(http PUT "$U/api/v1/repositories/$R/security" admin -H 'Content-Type: application/json' -d '{"scan_enabled":true,"scan_on_upload":false}')
echo "security: scan_enabled, scan_on_upload off -> $c"
for id in $(akcurl -fsS -H "$(admin_h)" "$U/api/v1/security/policies" | jq -r '(if type=="array" then . else .items end)[] | select(.name=="gate-g7-block-unscanned") | .id'); do
  http DELETE "$U/api/v1/security/policies/$id" admin >/dev/null; done
c=$(http POST "$U/api/v1/security/policies" admin -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg r "$rid" '{name:"gate-g7-block-unscanned",repository_id:$r,max_severity:"critical",block_unscanned:true,block_on_fail:true}')")
echo "policy block_unscanned -> $c"
check $G "block_unscanned policy on the scratch repository" "HTTP $c $(body | head -c 200)" grep -qE '^20' <<<"$c"

scan_now() { # version: trigger the scan and wait until the version is listed
  local id t0=$SECONDS
  id=$(akcurl -fsS -H "$(admin_h)" "$U/api/v1/repositories/$R/artifacts?per_page=100" | jq -r --arg p "$P/$1/$P-$1.zip" '.items[] | select(.path == $p) | .id')
  http POST "$U/api/v1/security/scan" admin -H 'Content-Type: application/json' -d "$(jq -nc --arg a "$id" '{artifact_id:$a}')" >/dev/null
  until akcurl -fsS -H "$(admin_h)" "$U/agentplugins/$R/$P/index.json" 2>/dev/null | jq -e --arg v "$1" 'any(.versions[]; .version == $v)' >/dev/null; do
    (( SECONDS - t0 > 600 )) && { echo "scan of $1 did not let it through in 600 s"; return 1; }; sleep 3; done
  echo "$P $1 scanned and listed after $((SECONDS - t0)) s"
  akcurl -fsS -H "$(admin_h)" "$U/api/v1/security/artifacts/$id/scans" | jq -c '[(if type == "array" then . else .items end)[] | {scan_type, status, findings_count}]' || true
  return 0
}
for v in 1.0.0 1.1.0; do claude_dir "$G_TMP/g7-$v" $P $v; python3 "$MKZIP" "$G_TMP/g7-$v.zip" "$G_TMP/g7-$v"; done
c=$(put_zip "$R" $P 1.0.0 "$G_TMP/g7-1.0.0.zip"); echo "publish $P 1.0.0 -> $c"
c=$(http GET "$U/agentplugins/$R/$P/1.0.0/$P-1.0.0.zip" admin); echo "download unscanned 1.0.0 -> $c"
check $G "an unscanned version downloads 403" "HTTP $c" test "$c" = 403
c=$(http GET "$U/agentplugins/$R/$P/index.json" admin); echo "index.json while 1.0.0 is unscanned -> $c"
check $G "a plugin with no scanned version has no index.json (404)" "HTTP $c" test "$c" = 404
scan_now 1.0.0; rc=$?; check $G "after its scan 1.0.0 is listed" "not listed in 600 s" test $rc = 0

c=$(put_zip "$R" $P 1.1.0 "$G_TMP/g7-1.1.0.zip"); echo "publish $P 1.1.0 -> $c"
hidden=1
for doc in marketplace claude-marketplace; do
  http GET "$U/agentplugins/$R/$doc.json" admin >/dev/null; echo "$doc.json: $(names "$G_TMP/body")"
  [[ $(names "$G_TMP/body") == "$P@1.0.0" ]] || hidden=0
done
http GET "$U/agentplugins/$R/$P/index.json" admin >/dev/null; v=$(jq -r '.latest + " [" + ([.versions[].version] | join(",")) + "]"' "$G_TMP/body"); echo "index.json: $v"
[[ $v == "1.0.0 [1.0.0]" ]] || hidden=0
check $G "unscanned 1.1.0 is hidden: the documents and index.json list 1.0.0" "see log" test $hidden = 1
c=$(http GET "$U/agentplugins/$R/$P/1.1.0/$P-1.1.0.zip" admin); echo "download unscanned 1.1.0 -> $c"
check $G "unscanned 1.1.0 downloads 403" "HTTP $c" test "$c" = 403

scan_now 1.1.0 || true
http GET "$U/agentplugins/$R/claude-marketplace.json" admin >/dev/null; m=$(names "$G_TMP/body"); echo "claude-marketplace.json: $m"
c=$(http GET "$U/agentplugins/$R/$P/1.1.0/$P-1.1.0.zip" admin); echo "download 1.1.0 after its scan -> $c"
check $G "after its scan 1.1.0 is the listed version and downloads 200" "$m, HTTP $c" bash -c "[[ '$m' == '$P@1.1.0' && $c == 200 ]]"
