#!/usr/bin/env bash
# G1 Access: who may read and who may publish the private registry.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G1
call - GET "$REG/servers" >/dev/null; why
check $G "anonymous read of the private registry is 401 mcp_unauthorized" "$(why)" is 401 mcp_unauthorized
call - POST "$REG/validate" --data-binary "@$ROOT/servers/acme-tickets/server.json" >/dev/null; why
check $G "anonymous /validate of the private registry is 401 (mcp-publisher validate sends no token)" "$(why)" is 401
call developer GET "$REG/servers" >/dev/null
check $G "the developer token reads the registry (200)" "$(why)" is 200
call developer POST "$REG/publish" --data-binary "@$ROOT/servers/acme-tickets/server.json" >/dev/null; why
check $G "the developer token cannot publish (403 mcp_forbidden)" "$(why)" is 403 mcp_forbidden
call ci POST "/mcp/mcp/v0.1/publish" --data-binary "@$ROOT/servers/acme-tickets/server.json" >/dev/null; why
check $G "the ci token cannot publish to the Virtual (403)" "$(why)" is 403
call admin POST "$UP/publish" --data-binary "@$ROOT/servers/acme-tickets/server.json" >/dev/null; why
check $G "nobody publishes to a Remote, not even an admin (405 mcp_read_only)" "$(why)" is 405 mcp_read_only
