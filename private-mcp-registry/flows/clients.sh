#!/usr/bin/env bash
# Step 2: point clients at the registry and install com.acme/tickets from it.
#   - the requests VS Code's MCP gallery and GitHub Copilot's registry check send, with curl
#     (the GUIs themselves are not driven here: see docs, "not machine-verified")
#   - the client configuration files, written to out/clients/ for reference
#   - Claude Code: `claude mcp add` with the command the registry entry describes, then
#     `claude mcp list`, which starts the server and checks that it answers (no account needed)
#   - mcp-call: start the same command, list the tools and call list_tickets
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
C="$ROOT/out/clients"; mkdir -p "$C"
REPO=${CLIENT_REPO:-mcp-internal}
ROOTURL=https://ak.internal/mcp/$REPO

say "What VS Code's gallery reads: GET /mcp/$REPO/v0.1/servers (developer token)"
call developer GET "/mcp/$REPO/v0.1/servers?limit=10" | jq -c '.servers[] | {name: .server.name, version: .server.version, isLatest: ._meta["io.modelcontextprotocol.registry/official"].isLatest}'
say "... and GET .../servers/com.acme%2Ftickets/versions/latest when you pick a server"
call developer GET "/mcp/$REPO/v0.1/servers/$(enc com.acme/tickets)/versions/latest" > "$C/tickets-latest.json"
jq -c '.server.packages[] | {registryType, identifier, version, registryBaseUrl}' "$C/tickets-latest.json"

say "What GitHub Copilot checks before it accepts a registry URL: the CORS preflight"
akcurl -sS -i -X OPTIONS "$U/mcp/$REPO/v0.1/servers" -H 'Origin: https://github.com' \
  -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization' \
  | grep -iE '^(HTTP|access-control)' | tr -d '\r'

say "Client configuration (written to out/clients/)"
jq -n --arg u "$ROOTURL" '{"chat.mcp.gallery.serviceUrl": $u}' > "$C/vscode-settings.json"
jq -n --arg u "$ROOTURL" '{mcp_registry_url: $u, policy: "Registry only"}' > "$C/copilot-org-policy.json"
cat "$C/vscode-settings.json"
echo "Copilot (organization settings > Copilot > Policies > MCP servers): registry URL $ROOTURL, access 'Registry only'"

# The install command a client derives from the registry entry: the npm package, its
# version, and registryBaseUrl as the npm registry.
pkg=$(jq -c '.server.packages[] | select(.registryType == "npm")' "$C/tickets-latest.json")
base=$(jq -r '.registryBaseUrl' <<<"$pkg"); ident=$(jq -r '.identifier' <<<"$pkg"); ver=$(jq -r '.version' <<<"$pkg")
CMD="npx -y --registry $base/ $ident@$ver"
echo "$CMD" > "$C/tickets-command.txt"

say "Claude Code: claude mcp add acme-tickets -- $CMD"
"$RUN" -h claude -t developer -- bash -c "$NPMRC
  cd /work && claude mcp remove acme-tickets --scope user >/dev/null 2>&1 || true
  claude mcp add acme-tickets --scope user -- $CMD
  claude mcp list
  claude mcp get acme-tickets" | tee "$C/claude-mcp.txt"

say "mcp-call: initialize, tools/list, tools/call list_tickets {\"status\":\"open\"}"
"$RUN" -t developer -- bash -c "$NPMRC
  mcp-call list_tickets '{\"status\":\"open\"}' -- $CMD" | tee "$C/tickets-call.json" | jq .
