#!/usr/bin/env bash
# G2 Publish rules: a version cannot be overwritten (409), and each ambiguous upload is
# refused with 400: no manifest, manifest name or version not the path's, SemVer build
# metadata, a ../ entry, a symbolic link, an uppercase slug, a two-part version, a file
# name that is not <name>-<version>.zip, a wrong X-Checksum-Sha256. None of the refused
# uploads appears in any index. Runs in a scratch repository, recreated each run.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G2; R=agent-plugins-gate-g2
fresh_repo "$R" || exit 1
claude_dir "$G_TMP/g2" acme-g2 1.0.0
python3 "$MKZIP" "$G_TMP/g2.zip" "$G_TMP/g2"
c=$(put_zip "$R" acme-g2 1.0.0 "$G_TMP/g2.zip"); echo "PUT acme-g2 1.0.0 -> $c $(body | jq -c '{name,version,harnesses,marketplace_name}' 2>/dev/null)"
check $G "valid publish -> 201" "HTTP $c" test "$c" = 201
c=$(put_zip "$R" acme-g2 1.0.0 "$G_TMP/g2.zip"); echo "PUT acme-g2 1.0.0 again, same bytes -> $c"
check $G "re-publish of an existing version, same bytes -> 409" "HTTP $c" test "$c" = 409
claude_dir "$G_TMP/g2b" acme-g2 1.0.0 "different bytes"
python3 "$MKZIP" "$G_TMP/g2b.zip" "$G_TMP/g2b"
c=$(put_zip "$R" acme-g2 1.0.0 "$G_TMP/g2b.zip"); echo "PUT acme-g2 1.0.0 again, different bytes -> $c"
check $G "overwrite of an existing version with different bytes -> 409" "HTTP $c" test "$c" = 409

refused=()
expect400() { # label name version zip [file] [curl args...]
  local label=$1 n=$2 v=$3 z=$4 f=${5:-} c; shift 5 2>/dev/null || shift $#
  c=$(http PUT "$U/agentplugins/$R/$n/$v/${f:-$n-$v.zip}" admin -H 'Content-Type: application/zip' --data-binary "@$z" "$@")
  echo "PUT $n/$v/${f:-$n-$v.zip} ($label) -> $c $(body | head -c 160)"
  check $G "refused with 400: $label" "HTTP $c" test "$c" = 400
  refused+=("$n")
}
M='.claude-plugin/plugin.json'
python3 "$MKZIP" "$G_TMP/n1.zip" --add 'skills/x/SKILL.md=---
name: x
description: x
---
x'
expect400 "no manifest marker" acme-g2-nomanifest 1.0.0 "$G_TMP/n1.zip" ""
python3 "$MKZIP" "$G_TMP/n2.zip" --add "$M"'={"name":"someone-else","version":"1.0.0"}'
expect400 "manifest name is not the path's name" acme-g2-name 1.0.0 "$G_TMP/n2.zip" ""
python3 "$MKZIP" "$G_TMP/n3.zip" --add "$M"'={"name":"acme-g2-ver","version":"0.9.0"}'
expect400 "manifest version is not the path's version" acme-g2-ver 1.0.0 "$G_TMP/n3.zip" ""
python3 "$MKZIP" "$G_TMP/n4.zip" --add "$M"'={"name":"acme-g2-build"}'
expect400 "SemVer build metadata (1.0.0+build)" acme-g2-build 1.0.0+build "$G_TMP/n4.zip" ""
python3 "$MKZIP" "$G_TMP/n5.zip" --add "$M"'={"name":"acme-g2-trav","version":"1.0.0"}' --add '../escape.md=outside the plugin'
expect400 "an entry with ../ (escapes the root)" acme-g2-trav 1.0.0 "$G_TMP/n5.zip" ""
python3 "$MKZIP" "$G_TMP/n6.zip" --add "$M"'={"name":"acme-g2-link","version":"1.0.0"}' --symlink 'skills/passwd=/etc/passwd'
expect400 "a symbolic link entry" acme-g2-link 1.0.0 "$G_TMP/n6.zip" ""
python3 "$MKZIP" "$G_TMP/n7.zip" --add "$M"'={"version":"1.0.0"}'
expect400 "uppercase slug (Acme-G2)" Acme-G2 1.0.0 "$G_TMP/n7.zip" ""
python3 "$MKZIP" "$G_TMP/n8.zip" --add "$M"'={"name":"acme-g2-semver"}'
expect400 "version not SemVer (1.0)" acme-g2-semver 1.0 "$G_TMP/n8.zip" ""
python3 "$MKZIP" "$G_TMP/n9.zip" --add "$M"'={"name":"acme-g2-file","version":"1.0.0"}'
expect400 "file name is not <name>-<version>.zip" acme-g2-file 1.0.0 "$G_TMP/n9.zip" "plugin.zip"
expect400 "X-Checksum-Sha256 does not match the body" acme-g2-sum 1.0.0 "$G_TMP/n9.zip" "" \
  -H "X-Checksum-Sha256: $(printf '0%.0s' {1..64})"

# None of the refused uploads in any document, and no index.json for any of them.
listed=0
for doc in marketplace claude-marketplace cursor-marketplace codex-marketplace vscode-marketplace; do
  http GET "$U/agentplugins/$R/$doc.json" admin >/dev/null; cp "$G_TMP/body" "$G_TMP/g2-$doc.json"
  echo "$doc.json: $(names "$G_TMP/g2-$doc.json")"
  for n in "${refused[@]}"; do jq -e --arg n "$n" 'any(.plugins[]; .name == $n)' "$G_TMP/g2-$doc.json" >/dev/null && listed=1; done
done
for n in "${refused[@]}"; do
  c=$(http GET "$U/agentplugins/$R/$n/index.json" admin); [[ $c == 404 ]] || { echo "$n/index.json -> $c"; listed=1; }
done
check $G "no refused upload appears in any document or has an index.json" "see log" test $listed = 0
check $G "the documents list exactly the valid publish" "$(names "$G_TMP/g2-marketplace.json")" \
  test "$(names "$G_TMP/g2-marketplace.json")" = "acme-g2@1.0.0"
