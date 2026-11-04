#!/usr/bin/env bash
# G5 The curated proxy (mcp-upstream): deny by default, approvals, deny wins, lookalikes,
# pins, drift, and which upstream packages can be pinned.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G5
st() { call admin GET "$CAT/catalog/servers/$1" | jq -r .status; }
call developer GET "$UP/servers/$(enc io.github.acme-labs/notes)/versions/1.1.0" >/dev/null
check $G "an unapproved version (notes 1.1.0) is the plain unknown-name 404" "$(why)" plain404
call developer GET "$UP/servers?limit=100" > "$GOUT/g5-list.json"
check $G "the listing has no unapproved, blocked or denied name" "see log" \
  jq -e '[.servers[].server.name] | (index("io.github.examp1e/weather") == null) and (index("io.github.evil-corp/exfil") == null) and (index("io.github.acme-labs/notes") != null)' "$GOUT/g5-list.json"
check $G "io.github.modelcontextprotocol/* was approved by the auto-approve glob" "status $(st io.github.modelcontextprotocol/server-memory)" \
  test "$(st io.github.modelcontextprotocol/server-memory)" = approved
call admin GET "$CAT/catalog/servers/io.github.examp1e/weather" > "$GOUT/g5-squat.json"
check $G "the lookalike io.github.examp1e/weather was flagged (typosquat of io.github.example/weather) and is blocked" "see log" \
  jq -e '.status == "blocked" and .flags.typosquat.similarTo == "io.github.example/weather"' "$GOUT/g5-squat.json"
call admin GET "$CAT/catalog/servers/io.github.evil-corp/exfil" > "$GOUT/g5-deny.json"
call developer GET "$UP/servers/$(enc io.github.evil-corp/exfil)/versions/latest" >/dev/null
check $G "deny wins: io.github.evil-corp/exfil is approved and denied, and not served" "$(why)" \
  bash -c "jq -e '.status == \"approved\" and .denied == true' '$GOUT/g5-deny.json' >/dev/null && [[ \$(cat '$FOUT/.code') == 404 ]]"
call admin POST "$CAT/catalog/bulk-approve" -d '{"pattern":"io.github.evil-corp/*","dryRun":true}' > "$GOUT/g5-bulk.json"
check $G "a bulk approval of io.github.evil-corp/* approves nothing" "see log" jq -e '.approved == 0 and .names == []' "$GOUT/g5-bulk.json"
call admin POST "$CAT/catalog/bulk-approve" -d '{"pattern":"io.github.evil-corp"}' >/dev/null
check $G "a bare namespace pattern is 422" "$(why)" is 422
call developer GET "$UP/servers/$(enc io.github.acme-labs/notes)/versions" | jq -c '[.servers[].server.version]' > "$GOUT/g5-pin.json"
check $G "the pinned name serves only the pinned version (notes: [1.0.0])" "$(cat "$GOUT/g5-pin.json")" test "$(cat "$GOUT/g5-pin.json")" = '["1.0.0"]'
call developer GET "$UP/servers/$(enc io.github.drifty/clock)/versions/1.0.0" > "$GOUT/g5-drift.json"
check $G "after drift and re-approval, clock 1.0.0 serves the stored document, not the new upstream bytes" "see log" \
  jq -e '.server.remotes[0].url == "https://clock.drifty.example/mcp"' "$GOUT/g5-drift.json"
n=$(audit '^MCP_SERVER_(CONTENT_DRIFT|REOPENED)$' 1000 | grep -c drifty)
check $G "the drift was audited (MCP_SERVER_CONTENT_DRIFT, MCP_SERVER_REOPENED)" "$n events" test "$n" -ge 2
call developer GET "$UP/servers/$(enc io.github.github/github-mcp-server)/versions/latest" > "$GOUT/g5-oci.json"
check $G "an OCI-backed upstream server is served pinned to the digest pulled through oci-ghcr" "see log" \
  jq -e 'any(.server.packages[]; .identifier | test("^ak\\.internal/oci-ghcr/github/github-mcp-server:2\\.1\\.0@sha256:[0-9a-f]{64}$"))' "$GOUT/g5-oci.json"
call admin GET "$CAT/catalog/servers/io.github.modelcontextprotocol/server-everything" > "$GOUT/g5-npm.json"
jq -c '{name, ingested: [.ingested[] | {version, unresolved: [.unresolved[].error]}]}' "$GOUT/g5-npm.json"
if jq -e '.ingested[0].unresolved == []' "$GOUT/g5-npm.json" >/dev/null; then
  pass $G "an npm-backed upstream server is served once its package was pulled through npm-remote"
else
  blocked ak-fix $G "an npm-backed upstream server is served once its package was pulled through npm-remote" \
    "Remote sync pins npm packages from artifacts only, not the proxy cache (findings F1)"
fi
