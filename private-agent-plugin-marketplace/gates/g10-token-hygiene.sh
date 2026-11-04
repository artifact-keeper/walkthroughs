#!/usr/bin/env bash
# G10 Token hygiene: a token in the path (/agentplugins/t/<token>/...) is replaced in the
# Caddy access log and in the backend's log, for the marketplace document and for the
# archive; a header token is redacted in the Caddy log. Claude Code keeps a token-in-path
# marketplace URL in plain text in three files (the exposure the docs state); the settings
# route keeps it in settings.json and Claude Code's copy of that entry in known_marketplaces.json. Both checked on the homes of `make consume-claude`.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G10; T=$(tok developer)
since=$(date -u +%FT%TZ); sleep 1
http GET "$U/agentplugins/t/$T/$REPO/claude-marketplace.json" - >/dev/null
url=$(jq -r '.plugins[] | select(.name == "acme-review") | .source.url' "$G_TMP/body")
c=$(http GET "$(host_url "$url")" -); echo "token-route document and archive -> $c"
http GET "$U/agentplugins/$REPO/claude-marketplace.json" developer >/dev/null
sleep 2
podman logs --since "$since" "$PROJECT-caddy" > "$G_TMP/caddy.log" 2>&1
podman logs --since "$since" "$PROJECT-backend" > "$G_TMP/backend.log" 2>&1
jq -r 'select(.request.uri != null) | [.request.uri, ((.request.headers.Authorization // ["-"])[0])] | @tsv' "$G_TMP/caddy.log" 2>/dev/null | tee "$G_TMP/caddy-uris.tsv"
check $G "Caddy access log: the token appears nowhere" "token found" bash -c "! grep -qF -- '$T' '$G_TMP/caddy.log'"
check $G "Caddy access log: document and archive URIs show /agentplugins/t/REDACTED/" "see log" \
  bash -c "grep -q '^/agentplugins/t/REDACTED/$REPO/claude-marketplace.json' '$G_TMP/caddy-uris.tsv' && grep -q '^/agentplugins/t/REDACTED/$REPO/acme-review/.*\.zip' '$G_TMP/caddy-uris.tsv'"
check $G "Caddy access log: an Authorization header is logged as REDACTED" "see log" \
  bash -c "grep -qP '^/agentplugins/$REPO/claude-marketplace.json\tREDACTED' '$G_TMP/caddy-uris.tsv'"
grep -F 'agentplugins/t/' "$G_TMP/backend.log" | head -4
check $G "backend log: the token appears nowhere" "token found" bash -c "! grep -qF -- '$T' '$G_TMP/backend.log'"
check $G "backend log: token-route requests are logged with [REDACTED]" "no redacted line" grep -qF 'agentplugins/t/[REDACTED]/' "$G_TMP/backend.log"

CH="$ROOT/out/homes/claude-token/.claude"
if [[ -d $CH ]]; then
  found=$(grep -rlF -- "$T" "$CH" | sed "s#^$CH/#~/.claude/#" | sort | tr '\n' ' ')
  echo "files under ~/.claude holding the token after the token-in-path route: $found"
  check $G "Claude Code keeps a token-in-path URL in plain text in settings.json, known_marketplaces.json and the cached marketplace (documented exposure)" "found in: $found" \
    bash -c "[[ '$found' == *settings.json* && '$found' == *known_marketplaces.json* && '$found' == *marketplaces/agent-plugins* ]]"
else
  fail $G "Claude Code keeps a token-in-path URL in plain text (documented exposure)" "$CH missing: run make consume-claude first"
fi
SH="$ROOT/out/homes/claude-settings/.claude"
if [[ -d $SH ]]; then
  found=$(grep -rlF -- "$T" "$SH" | sed "s#^$SH/#~/.claude/#" | sort | tr '\n' ' ')
  echo "files under ~/.claude holding the token after the settings route: $found"
  # shellcheck disable=SC2088  # a literal ~ in the file list, not a path
  check $G "the settings route keeps the token out of every URL and cache: only settings.json and its copy in known_marketplaces.json" "found in: $found" \
    test "$found" = "~/.claude/plugins/known_marketplaces.json ~/.claude/settings.json "
fi
