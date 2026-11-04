#!/usr/bin/env bash
# G9 Generic upload: a zip written into the repository through the generic REST upload
# (PUT /api/v1/repositories/{key}/artifacts/{path}) was never validated as a plugin, so the
# format neither indexes nor serves it, even at a path that looks like a version.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G9; R=agent-plugins-gate-g9
fresh_repo "$R" || exit 1
claude_dir "$G_TMP/g9" acme-g9 1.0.0; python3 "$MKZIP" "$G_TMP/g9.zip" "$G_TMP/g9"
claude_dir "$G_TMP/g9b" acme-g9 9.0.0; python3 "$MKZIP" "$G_TMP/g9b.zip" "$G_TMP/g9b"
claude_dir "$G_TMP/g9c" acme-g9-sideload 1.0.0; python3 "$MKZIP" "$G_TMP/g9c.zip" "$G_TMP/g9c"
c=$(put_zip "$R" acme-g9 1.0.0 "$G_TMP/g9.zip"); echo "native PUT acme-g9 1.0.0 -> $c"
check $G "native publish of acme-g9 1.0.0 -> 201" "HTTP $c" test "$c" = 201
c=$(http PUT "$U/api/v1/repositories/$R/artifacts/acme-g9/9.0.0/acme-g9-9.0.0.zip" admin -H 'Content-Type: application/zip' --data-binary "@$G_TMP/g9b.zip")
echo "generic REST PUT acme-g9/9.0.0/acme-g9-9.0.0.zip -> $c"
c2=$(http PUT "$U/api/v1/repositories/$R/artifacts/acme-g9-sideload/1.0.0/acme-g9-sideload-1.0.0.zip" admin -H 'Content-Type: application/zip' --data-binary "@$G_TMP/g9c.zip")
echo "generic REST PUT acme-g9-sideload/1.0.0/acme-g9-sideload-1.0.0.zip -> $c2"
check $G "the generic REST upload itself is accepted (it is how replication delivers)" "HTTP $c $c2" \
  bash -c "[[ $c =~ ^20 && $c2 =~ ^20 ]]"
http GET "$U/agentplugins/$R/acme-g9/index.json" admin >/dev/null; v=$(jq -r '[.versions[].version] | join(",")' "$G_TMP/body")
echo "acme-g9/index.json versions: $v"
check $G "index.json lists only the native version" "versions $v" test "$v" = 1.0.0
c=$(http GET "$U/agentplugins/$R/acme-g9/9.0.0/acme-g9-9.0.0.zip" admin); echo "native GET acme-g9 9.0.0 -> $c"
check $G "the generic upload is not downloadable through /agentplugins (404)" "HTTP $c" test "$c" = 404
c=$(http GET "$U/agentplugins/$R/acme-g9-sideload/index.json" admin); echo "acme-g9-sideload/index.json -> $c"
check $G "a plugin that only exists through the generic upload has no index.json (404)" "HTTP $c" test "$c" = 404
http GET "$U/agentplugins/$R/marketplace.json" admin >/dev/null; m=$(names "$G_TMP/body"); echo "marketplace.json: $m"
check $G "marketplace.json lists only acme-g9@1.0.0" "$m" test "$m" = "acme-g9@1.0.0"
