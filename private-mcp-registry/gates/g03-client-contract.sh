#!/usr/bin/env bash
# G3 What clients read: the registry API shape, the served coordinates, CORS, /v0, and two
# real clients: Claude Code (claude mcp list starts the server) and an MCP client calling a tool.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G3
call developer GET "$REG/servers?limit=100" > "$GOUT/g3-list.json"
check $G "GET /v0.1/servers answers the upstream envelope {servers[{server,_meta}], metadata.count}" "$(why)" \
  jq -e '(.servers | type == "array") and (.metadata.count | type == "number") and all(.servers[]; has("server") and has("_meta"))' "$GOUT/g3-list.json"
call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/latest" > "$GOUT/g3-latest.json"
check $G "versions/latest of com.acme/tickets is 1.0.0 (1.0.2 is held)" "$(why)" jq -e '.server.version == "1.0.0"' "$GOUT/g3-latest.json"
check $G "the npm package is served with registryBaseUrl https://ak.internal/npm/npm-internal" "see log" \
  jq -e 'any(.server.packages[]; .registryType == "npm" and .registryBaseUrl == "https://ak.internal/npm/npm-internal" and .version == "1.0.0")' "$GOUT/g3-latest.json"
check $G "the OCI package is served as ak.internal/oci-internal/...:1.0.0@sha256:<digest>" "see log" \
  jq -e 'any(.server.packages[]; .registryType == "oci" and (.identifier | test("^ak\\.internal/oci-internal/acme/tickets-mcp:1\\.0\\.0@sha256:[0-9a-f]{64}$")))' "$GOUT/g3-latest.json"
call developer GET "/mcp/mcp-internal/v0/servers/$(enc com.acme/tickets)/versions/latest" > "$GOUT/g3-v0.json"
check $G "/v0 answers the same document as /v0.1" "differs" bash -c "diff <(jq -S .server '$GOUT/g3-latest.json') <(jq -S .server '$GOUT/g3-v0.json') >/dev/null"
akcurl -sS -i -X OPTIONS "$U$REG/servers" -H 'Origin: https://github.com' -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: authorization' | tr -d '\r' > "$GOUT/g3-cors.txt"
grep -i '^access-control' "$GOUT/g3-cors.txt"
check $G "CORS preflight allows any origin, GET and the Authorization header" "see log" \
  bash -c "grep -qi '^access-control-allow-origin: \*' '$GOUT/g3-cors.txt' && grep -qi '^access-control-allow-headers:.*authorization' '$GOUT/g3-cors.txt'"
CMD="npx -y --registry https://ak.internal/npm/npm-internal/ @acme/tickets-mcp@1.0.0"
"$RUN" -h g3-claude -t developer -- bash -c "$NPMRC
  cd /work && claude mcp remove acme-tickets --scope user >/dev/null 2>&1 || true
  claude mcp add acme-tickets --scope user -- $CMD >/dev/null && claude mcp list" > "$GOUT/g3-claude.txt" 2>&1
cat "$GOUT/g3-claude.txt"
check $G "Claude Code: claude mcp list starts the server installed from ak.internal and reports it Connected" "see log" \
  grep -q 'acme-tickets: .*Connected' "$GOUT/g3-claude.txt"
"$RUN" -t developer -- bash -c "$NPMRC; mcp-call list_tickets '{\"status\":\"open\"}' -- $CMD" > "$GOUT/g3-call.json" 2>/dev/null
cat "$GOUT/g3-call.json"
check $G "an MCP client calls list_tickets on the installed server and gets the two open tickets" "see log" \
  jq -e '.serverInfo.name == "acme-tickets" and (.call.content[0].text | fromjson | length == 2)' "$GOUT/g3-call.json"
