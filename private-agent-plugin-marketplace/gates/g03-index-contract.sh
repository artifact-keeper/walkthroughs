#!/usr/bin/env bash
# G3 Index contract. On agent-plugins: claude-marketplace.json follows Claude Code's rules
# (names, owner, archive sources, sha256 of the actual bytes, version = path version), ETag
# and 304, Cache-Control no-cache on plain routes and private, no-store on the token route,
# token-route archive URLs keep the token prefix. In a scratch repository: membership of
# each document follows the harness table, and each document picks its own latest (a
# plugin whose newest version is Cursor-only stays at its older version for Claude Code).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G3
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

c=$(http GET "$U/agentplugins/$REPO/claude-marketplace.json" developer); cp "$G_TMP/body" "$G_TMP/g3-claude.json"
echo "claude-marketplace.json -> $c: name=$(jq -r .name "$G_TMP/g3-claude.json") owner=$(jq -c .owner "$G_TMP/g3-claude.json") plugins=$(names "$G_TMP/g3-claude.json")"
check $G "marketplace name and every entry name match Claude Code's rule, no '..'" "see log" \
  jq -e --arg re "$NAME_RE" '([.name] + [.plugins[].name]) | all(test($re) and (contains("..") | not))' "$G_TMP/g3-claude.json"
check $G "owner.name is present" "owner $(jq -c .owner "$G_TMP/g3-claude.json")" jq -e '.owner.name | type == "string" and length > 0' "$G_TMP/g3-claude.json"
check $G "no \$schema in claude-marketplace.json" "has \$schema" jq -e 'has("$schema") | not' "$G_TMP/g3-claude.json"
check $G "every source is {source: archive, url: https://..., sha256: 64 hex}" "see log" \
  jq -e 'all(.plugins[]; .source.source == "archive" and (.source.url | startswith("https://")) and (.source.sha256 | test("^[0-9a-f]{64}$")))' "$G_TMP/g3-claude.json"
check $G "each entry's version equals the version in its archive path" "see log" \
  jq -e 'all(.plugins[]; (.source.url | split("/") | .[-2]) == .version and (.source.url | split("/") | .[-1]) == "\(.name)-\(.version).zip")' "$G_TMP/g3-claude.json"
bad=0
while IFS=$'\t' read -r n url sha; do
  got=$(akcurl -fsS -H "Authorization: Bearer $(tok developer)" "$(host_url "$url")" | sha256sum | cut -d' ' -f1)
  echo "$n: index $sha, bytes $got"; [[ $got == "$sha" ]] || bad=1
done < <(jq -r '.plugins[] | [.name, .source.url, .source.sha256] | @tsv' "$G_TMP/g3-claude.json")
check $G "sha256 in the document matches the downloaded bytes, for every entry" "mismatch" test $bad = 0

et=$(header ETag); cc=$(header Cache-Control); echo "ETag: $et  Cache-Control: $cc"
c=$(http GET "$U/agentplugins/$REPO/claude-marketplace.json" developer -H "If-None-Match: $et"); echo "If-None-Match -> $c"
check $G "ETag present and If-None-Match answers 304" "ETag '$et', HTTP $c" bash -c "[[ -n '$et' && $c == 304 ]]"
check $G "plain route Cache-Control: no-cache" "'$cc'" test "$cc" = no-cache

T=$(tok developer)
c=$(http GET "$U/agentplugins/t/$T/$REPO/claude-marketplace.json" -); cc=$(header Cache-Control); rp=$(header Referrer-Policy)
cp "$G_TMP/body" "$G_TMP/g3-token.json"
echo "token route -> $c, Cache-Control: $cc, Referrer-Policy: $rp"
check $G "token route Cache-Control: private, no-store" "HTTP $c '$cc'" bash -c "[[ $c == 200 && '$cc' == 'private, no-store' ]]"
check $G "token route Referrer-Policy: no-referrer, as clients see it through Caddy" "'$rp'" test "$rp" = no-referrer
# The same request straight to the backend, past Caddy (which restores the header, F1).
rpb=$(podman run --rm --network "$NET" docker.io/library/alpine:3.24 wget -S -O /dev/null \
      "http://backend:8080/agentplugins/t/$T/$REPO/claude-marketplace.json" 2>&1 | grep -i '^ *referrer-policy:' | sed 's/.*: *//' | tr -d '\r')
echo "Referrer-Policy from the backend itself: $rpb"
if [[ $rpb == no-referrer ]]; then pass $G "the backend itself sends Referrer-Policy: no-referrer on the token route"
else blocked F1 $G "the backend itself sends Referrer-Policy: no-referrer on the token route" "it sends '$rpb' (findings.md F1; Caddy restores no-referrer)"; fi
check $G "token route archive URLs keep the /agentplugins/t/<token>/ prefix" "see log" \
  jq -e --arg p "https://ak.internal/agentplugins/t/$T/$REPO/" 'all(.plugins[]; .source.url | startswith($p))' "$G_TMP/g3-token.json"
url=$(jq -r '.plugins[0].source.url' "$G_TMP/g3-token.json")
c=$(http GET "$(host_url "$url")" -); cc=$(header Cache-Control)
echo "token route archive (no Authorization header) -> $c, Cache-Control: $cc"
check $G "token route archive downloads with no header, Cache-Control: private, no-store" "HTTP $c '$cc'" \
  bash -c "[[ $c == 200 && '$cc' == 'private, no-store' ]]"

# --- membership and per-harness latest, in a scratch repository ---------------------------
R=agent-plugins-gate-g3
fresh_repo "$R" || exit 1
mk() { # name version file=json ...   (a zip of manifests plus one skill)
  local n=$1 v=$2; shift 2; local a=(--add "skills/s/SKILL.md=---
name: s
description: fixture
---
$n $v")
  for m in "$@"; do a+=(--add "$m"); done
  python3 "$MKZIP" "$G_TMP/$n-$v.zip" "${a[@]}"
  local c; c=$(put_zip "$R" "$n" "$v" "$G_TMP/$n-$v.zip"); echo "publish $n $v -> $c $(body | jq -c .harnesses 2>/dev/null)"
}
J() { jq -nc --arg n "$1" --arg v "$2" '{name:$n,version:$v}'; }
S() { jq -nc --arg n "$1" --arg v "$2" '{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",name:$n,version:$v}'; }
mk g3-claude 1.0.0 ".claude-plugin/plugin.json=$(J g3-claude 1.0.0)"
mk g3-standard 1.0.0 "plugin.json=$(S g3-standard 1.0.0)"
mk g3-cursor 1.0.0 ".cursor-plugin/plugin.json=$(J g3-cursor 1.0.0)"
mk g3-codex 1.0.0 ".codex-plugin/plugin.json=$(J g3-codex 1.0.0)"
mk g3-mixed 1.0.0 ".claude-plugin/plugin.json=$(J g3-mixed 1.0.0)" ".cursor-plugin/plugin.json=$(J g3-mixed 1.0.0)"
mk g3-mixed 2.0.0 ".cursor-plugin/plugin.json=$(J g3-mixed 2.0.0)"
mk g3-pre 1.9.0 ".claude-plugin/plugin.json=$(J g3-pre 1.9.0)"
mk g3-pre 2.0.0-rc.1 ".claude-plugin/plugin.json=$(J g3-pre 2.0.0-rc.1)"
mk g3-plain 1.0.0 "plugin.json=$(J g3-plain 1.0.0)" ".claude-plugin/plugin.json=$(J g3-plain 1.0.0)"
declare -A want=(
  [marketplace]="g3-claude@1.0.0,g3-codex@1.0.0,g3-cursor@1.0.0,g3-mixed@2.0.0,g3-plain@1.0.0,g3-pre@2.0.0-rc.1,g3-standard@1.0.0"
  [claude-marketplace]="g3-claude@1.0.0,g3-mixed@1.0.0,g3-plain@1.0.0,g3-pre@2.0.0-rc.1,g3-standard@1.0.0"
  [cursor-marketplace]="g3-cursor@1.0.0,g3-mixed@2.0.0,g3-standard@1.0.0"
  [codex-marketplace]="g3-codex@1.0.0,g3-standard@1.0.0"
  [vscode-marketplace]="g3-standard@1.0.0"
)
for doc in marketplace claude-marketplace cursor-marketplace codex-marketplace vscode-marketplace; do
  http GET "$U/agentplugins/$R/$doc.json" admin >/dev/null; got=$(names "$G_TMP/body")
  echo "$doc.json: $got"
  check $G "membership and latest of $doc.json" "got $got, want ${want[$doc]}" test "$got" = "${want[$doc]}"
done
http GET "$U/agentplugins/$R/g3-mixed/index.json" admin >/dev/null
echo "g3-mixed/index.json: $(jq -c '{latest, versions: [.versions[] | {version, harnesses}]}' "$G_TMP/body")"
check $G "index.json: newest first, latest = 2.0.0, harnesses per version" "see log" \
  jq -e '.latest == "2.0.0" and ([.versions[].version] == ["2.0.0","1.0.0"]) and (.versions[0].harnesses == ["cursor"])' "$G_TMP/body"
