#!/usr/bin/env bash
# G8 One URL: the Virtual mcp merges mcp-internal and mcp-upstream; hosted shadows remote.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G8 V=/mcp/mcp/v0.1
call developer GET "$UP/servers/$(enc com.acme/tickets)/versions/9.9.9" >/dev/null
check $G "the squatter com.acme/tickets 9.9.9 is approved and served by mcp-upstream itself" "$(why)" is 200
call developer GET "$V/servers/$(enc com.acme/tickets)/versions" > "$GOUT/g8-versions.json"
check $G "through the Virtual, com.acme/tickets has only the hosted versions" "see log" \
  jq -e '[.servers[].server.version] | index("9.9.9") == null and index("1.0.0") != null' "$GOUT/g8-versions.json"
call developer GET "$V/servers/$(enc com.acme/tickets)/versions/9.9.9" >/dev/null
check $G "... and 9.9.9 is the plain 404" "$(why)" plain404
call developer GET "$V/servers?version=latest&limit=100" > "$GOUT/g8-list.json"
check $G "the merged listing has hosted and approved upstream servers, each from its member" "see log" \
  jq -e '(any(.servers[]; .server.name == "com.acme/tickets" and ._meta["com.artifactkeeper.registry/source"].repository == "mcp-internal"))
     and (any(.servers[]; .server.name == "io.github.example/weather" and ._meta["com.artifactkeeper.registry/source"].repository == "mcp-upstream"))
     and all(.servers[]; ._meta["com.artifactkeeper.registry/source"].virtualRepository == "mcp")' "$GOUT/g8-list.json"
call developer GET "$V/servers?cursor=bm90LWEtY3Vyc29y" >/dev/null
check $G "a malformed cursor is 400 mcp_invalid_query" "$(why)" is 400 mcp_invalid_query
call admin POST "$V/publish" --data-binary "@$ROOT/servers/acme-tickets/server.json" >/dev/null
check $G "a publish to the Virtual is 405 mcp_read_only" "$(why)" is 405 mcp_read_only
