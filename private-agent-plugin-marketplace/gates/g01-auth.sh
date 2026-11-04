#!/usr/bin/env bash
# G1 Auth: the private repository refuses anonymous reads (401), the developer's read
# token reads (200) but cannot publish (403), a token scoped to another repository is
# refused, the public repository reads anonymously (200), and no committed file carries a
# credential.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G1
DOC="$U/agentplugins/$REPO/claude-marketplace.json"
ZIP="$U/agentplugins/$REPO/acme-review/1.0.0/acme-review-1.0.0.zip"

c=$(http GET "$DOC" -); echo "anonymous GET claude-marketplace.json -> $c"
check $G "anonymous read of the private repository -> 401" "HTTP $c" test "$c" = 401
c=$(http GET "$ZIP" -); echo "anonymous GET acme-review-1.0.0.zip -> $c"
check $G "anonymous download from the private repository -> 401" "HTTP $c" test "$c" = 401

c=$(http GET "$DOC" developer); echo "developer token GET claude-marketplace.json -> $c"
check $G "developer read token reads the marketplace -> 200" "HTTP $c" test "$c" = 200
c=$(http GET "$ZIP" developer); echo "developer token GET acme-review-1.0.0.zip -> $c"
check $G "developer read token downloads a version -> 200" "HTTP $c" test "$c" = 200

python3 "$MKZIP" "$G_TMP/g1.zip" --add '.claude-plugin/plugin.json={"name":"acme-g1","version":"1.0.0"}'
c=$(put_zip "$REPO" acme-g1 1.0.0 "$G_TMP/g1.zip" developer); echo "developer token PUT acme-g1-1.0.0.zip -> $c"
check $G "developer read token cannot publish -> 403" "HTTP $c" test "$c" = 403
c=$(put_zip "$REPO" acme-g1 1.0.0 "$G_TMP/g1.zip" -); echo "anonymous PUT acme-g1-1.0.0.zip -> $c"
check $G "anonymous publish -> 401" "HTTP $c" test "$c" = 401

c=$(http GET "$DOC" public-ci); echo "token scoped to agent-plugins-public GET agent-plugins/claude-marketplace.json -> $c"
check $G "a token for another repository cannot read this one (401/403/404)" "HTTP $c" grep -qE '^(401|403|404)$' <<<"$c"
c=$(put_zip "$REPO" acme-g1 1.0.0 "$G_TMP/g1.zip" public-ci); echo "token scoped to agent-plugins-public PUT into agent-plugins -> $c"
check $G "a write token for another repository cannot publish here (401/403/404)" "HTTP $c" grep -qE '^(401|403|404)$' <<<"$c"

c=$(http GET "$U/agentplugins/t/not-a-token/$REPO/claude-marketplace.json" -); echo "bogus token in the path -> $c"
check $G "a bogus path token -> 401" "HTTP $c" test "$c" = 401
c=$(http GET "$U/agentplugins/t/$(tok developer)/$REPO/claude-marketplace.json" -); echo "developer token in the path -> $c"
check $G "the developer token in the path reads the marketplace -> 200" "HTTP $c" test "$c" = 200

c=$(http GET "$U/agentplugins/agent-plugins-public/claude-marketplace.json" -); echo "anonymous GET agent-plugins-public/claude-marketplace.json -> $c"
ok=0; [[ $c == 200 ]] && url=$(jq -r '.plugins[0].source.url' "$G_TMP/body") && \
  c2=$(http GET "$(host_url "$url")" -) && echo "anonymous GET $url -> $c2" && [[ $c2 == 200 ]] && ok=1
check $G "public repository: anonymous marketplace and download -> 200" "HTTP $c ${c2:-}" test $ok = 1

# No credential in any committed file: every token value, the admin password, and
# token-shaped strings in URLs, in every file git tracks (or every file outside the
# gitignored state directories when this is not a git checkout).
cd "$ROOT" || exit 1
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then mapfile -t files < <(git ls-files .)
else mapfile -t files < <(find . -type f ! -path './out/*' ! -path './registry/.tokens/*' ! -path './registry/out/*' ! -path './registry/.env' ! -path './client/.work/*'); fi
leak=0
for t in "$TOKENS"/*.token "$TOKENS"/*.password; do
  v=$(<"$t"); [[ -n $v ]] || continue
  if grep -lF -- "$v" "${files[@]}" 2>/dev/null; then echo "value of $(basename "$t") found in the files above"; leak=1; fi
done
grep -l -- "$ADMIN_PASSWORD" "${files[@]}" 2>/dev/null && { echo "ADMIN_PASSWORD found"; leak=1; }
grep -nE '/agentplugins/t/[A-Za-z0-9_-]{16,}/|"Authorization": *"Bearer [A-Za-z0-9_-]{16,}' "${files[@]}" 2>/dev/null && leak=1
echo "scanned ${#files[@]} committed files"
check $G "no credential in any committed file (${#files[@]} files)" "see log" test $leak = 0
