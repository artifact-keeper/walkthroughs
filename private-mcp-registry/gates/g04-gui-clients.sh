#!/usr/bin/env bash
# G4 GUI clients. VS Code's MCP gallery and GitHub Copilot's private-registry policy are not
# driven here: they need a person (and, for Copilot, an organization). G3 checks the requests
# they send. These lines say what to do by hand.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G4
blocked gui $G "VS Code lists and installs com.acme/tickets from the gallery" \
  "set chat.mcp.gallery.serviceUrl to https://ak.internal/mcp/mcp (out/clients/vscode-settings.json), trust the CA, open Extensions > MCP Servers, install Acme tickets"
blocked gui $G "Copilot accepts the registry and, under 'Registry only', refuses a server that is not in it" \
  "organization settings > Copilot > Policies > MCP: registry URL https://ak.internal/mcp/mcp (reachable by the clients), access Registry only"
