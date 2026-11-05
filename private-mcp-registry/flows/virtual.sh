#!/usr/bin/env bash
# Step 6: one URL for clients. A Virtual mcp repository, `mcp`, merges mcp-internal (hosted,
# priority 1) and mcp-upstream (Remote, priority 2). A hosted name always shadows a Remote
# one: com.acme/tickets 9.9.9, published upstream by someone outside Acme and approved on the
# Remote by mistake, never reaches a client of the Virtual.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
V=/mcp/mcp/v0.1

say "The squatter upstream: approve com.acme/tickets on mcp-upstream (a mistake on purpose)"
call admin POST "$CAT/catalog/$(cid com.acme/tickets)/approve" \
  -d '{"reason":"approved by mistake; the Virtual must still serve the internal server"}' | jq -c '{name: .item.name, status: .item.status}'
call developer GET "$UP/servers/$(enc com.acme/tickets)/versions/latest" | jq -c '{from: "mcp-upstream", version: .server.version, url: .server.remotes[0].url}'

say "The Virtual repository mcp: mcp-internal first, then mcp-upstream"
ensure_repo mcp '{"key":"mcp","name":"Acme MCP registry (internal first, then curated public)","format":"mcp",
  "repo_type":"virtual","visibility":"private"}'
call admin PUT /api/v1/repositories/mcp/members -d '{"members":[{"member_key":"mcp-internal","priority":1},{"member_key":"mcp-upstream","priority":2}]}' >/dev/null
echo "members: HTTP $(code)"
grant_read developer mcp

say "GET $V/servers?version=latest: one entry per name, and where it comes from"
call developer GET "$V/servers?version=latest&limit=100" | jq -c '.servers[] | {name: .server.name, version: .server.version,
  member: ._meta["com.artifactkeeper.registry/source"].repository}'
say "Hosted shadows remote: every version of com.acme/tickets through the Virtual, and 9.9.9 directly"
call developer GET "$V/servers/$(enc com.acme/tickets)/versions" | jq -c '[.servers[].server.version]'
show developer GET "$V/servers/$(enc com.acme/tickets)/versions/9.9.9"

say "A cursor walk at limit=3 visits every entry once"
cursor="" n=0
while :; do
  q="limit=3"; [[ -n $cursor ]] && q="$q&cursor=$(jq -rn --arg c "$cursor" '$c | @uri')"
  page=$(call developer GET "$V/servers?$q")
  n=$((n + $(jq '.servers | length' <<<"$page")))
  cursor=$(jq -r '.metadata.nextCursor // empty' <<<"$page"); [[ -z $cursor ]] && break
done
echo "entries: $n (the unpaged listing has $(call developer GET "$V/servers?limit=100" | jq '.servers | length'))"

say "Writes go to a member, not the Virtual"
show admin POST "$V/publish" --data-binary "@$ROOT/servers/acme-tickets/server.json"

say "Clients now use one URL: https://ak.internal/mcp/mcp"
CLIENT_REPO=mcp "$(dirname "${BASH_SOURCE[0]}")/clients.sh" 2>&1 | sed -n '/What VS Code/,/^== What GitHub/p' | head -12
