#!/usr/bin/env bash
# G6 Immutability after delete: delete a version through the REST API; meanwhile every
# document falls back to the previous version and the download is 404; re-publishing the
# deleted version with different bytes is 409; with identical bytes it is 201 and the
# version is back. Fixtures are deterministic zips, so "identical" holds across runs.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G6; R=agent-plugins-gate-g6; P=acme-g6
fresh_repo "$R" || exit 1
for v in 1.0.0 1.1.0; do claude_dir "$G_TMP/g6-$v" $P $v; python3 "$MKZIP" "$G_TMP/g6-$v.zip" "$G_TMP/g6-$v"
  c=$(put_zip "$R" $P $v "$G_TMP/g6-$v.zip"); echo "publish $P $v -> $c"; done
latest() { http GET "$U/agentplugins/$R/claude-marketplace.json" admin >/dev/null; jq -r --arg p $P '.plugins[] | select(.name == $p) | .version' "$G_TMP/body"; }
l=$(latest); echo "claude-marketplace.json lists $P at $l"
check $G "before the delete the document lists 1.1.0" "lists $l" test "$l" = 1.1.0

c=$(http DELETE "$U/api/v1/repositories/$R/artifacts/$P/1.1.0/$P-1.1.0.zip" admin); echo "DELETE $P 1.1.0 -> $c"
check $G "REST delete of 1.1.0 -> 2xx" "HTTP $c" grep -qE '^20' <<<"$c"
l=$(latest); echo "claude-marketplace.json lists $P at $l"
check $G "meanwhile the document falls back to 1.0.0" "lists $l" test "$l" = 1.0.0
http GET "$U/agentplugins/$R/$P/index.json" admin >/dev/null; v=$(jq -r '[.versions[].version] | join(",")' "$G_TMP/body"); echo "index.json versions: $v"
check $G "index.json lists only 1.0.0" "$v" test "$v" = 1.0.0
c=$(http GET "$U/agentplugins/$R/$P/1.1.0/$P-1.1.0.zip" admin); echo "GET deleted 1.1.0 -> $c"
check $G "the deleted version downloads 404" "HTTP $c" test "$c" = 404

claude_dir "$G_TMP/g6-evil" $P 1.1.0 "same version, new bytes"; python3 "$MKZIP" "$G_TMP/g6-evil.zip" "$G_TMP/g6-evil"
c=$(put_zip "$R" $P 1.1.0 "$G_TMP/g6-evil.zip"); echo "re-publish 1.1.0 with different bytes -> $c"
check $G "re-publish of the deleted version with different bytes -> 409" "HTTP $c" test "$c" = 409
c=$(put_zip "$R" $P 1.1.0 "$G_TMP/g6-1.1.0.zip"); echo "re-publish 1.1.0 with identical bytes -> $c"
check $G "re-publish with identical bytes restores it -> 201" "HTTP $c" test "$c" = 201
l=$(latest); got=$(akcurl -fsS -H "$(admin_h)" "$U/agentplugins/$R/$P/1.1.0/$P-1.1.0.zip" | sha256sum | cut -d' ' -f1)
echo "document lists $l; restored bytes $got, original $(sha256sum "$G_TMP/g6-1.1.0.zip" | cut -d' ' -f1)"
check $G "after the restore the document lists 1.1.0 and serves the original bytes" "lists $l" \
  bash -c "[[ '$l' == 1.1.0 && '$got' == $(sha256sum "$G_TMP/g6-1.1.0.zip" | cut -d' ' -f1) ]]"
