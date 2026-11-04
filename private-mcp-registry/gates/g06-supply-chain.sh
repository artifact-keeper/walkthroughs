#!/usr/bin/env bash
# G6 Supply-chain gates: a pinned digest survives a tag move and cannot be deleted, a
# quarantined package hides its server, a prompt-injection finding holds a version.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G6
served=$(call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/1.0.0" | jq -r '.server.packages[] | select(.registryType == "oci") | .identifier')
now=$("$RUN" -t ci -- bash -c 'skopeo inspect --creds ci:$AK_TOKEN docker://ak.internal/oci-internal/acme/tickets-mcp:1.0.0 | jq -r .Digest')
echo "served: $served"; echo "tag now: $now"
check $G "the served digest is the one pinned at publish, not what the moved tag names now" "same digest: the tag never moved" \
  bash -c "[[ '$served' != *'$now' ]]"
n=$(audit '^MCP_PIN_DRIFT_DETECTED$' 1000 | grep -c 'com.acme/tickets')
check $G "the tag move was audited (MCP_PIN_DRIFT_DETECTED)" "$n events" test "$n" -ge 1
call admin DELETE "/v2/oci-internal/acme/tickets-mcp/manifests/${served#*@}" >/dev/null; why
check $G "deleting the pinned manifest by digest is refused, even for an admin (405)" "$(why)" is 405
"$RUN" -t developer -- bash -c "skopeo inspect --creds developer:\$AK_TOKEN docker://ak.internal/oci-internal/acme/tickets-mcp@${served#*@} | jq -r .Digest" > "$GOUT/g6-pull.txt" 2>&1
check $G "the pinned digest still pulls" "$(cat "$GOUT/g6-pull.txt")" grep -q "${served#*@}" "$GOUT/g6-pull.txt"
aid=$(call admin GET "/api/v1/repositories/npm-internal/artifacts?per_page=100" | jq -r '.items[] | select(.path | endswith("/tickets-mcp-1.0.0.tgz")) | .id')
call admin POST "/api/v1/quarantine/$aid/quarantine" -d '{"reason":"gate G6"}' >/dev/null
call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/1.0.0" >/dev/null; why
check $G "quarantining the npm tarball hides com.acme/tickets 1.0.0 (404 mcp_backing_artifact_blocked)" "$(why)" is 404 mcp_backing_artifact_blocked
call developer GET "$REG/servers?search=com.acme/tickets" > "$GOUT/g6-list.json"
check $G "... and drops it from the listing" "see log" jq -e '[.servers[] | select(.server.name == "com.acme/tickets")] | length == 0' "$GOUT/g6-list.json"
call admin POST "/api/v1/quarantine/$aid/release" -d '{}' >/dev/null
call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/1.0.0" >/dev/null
check $G "releasing it serves the version again" "$(why)" is 200
call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/1.0.2" >/dev/null; why
check $G "the version whose tool description reads as an injection is held (404 mcp_rejected, scan_policy)" "$(why)" \
  bash -c "[[ \$(cat '$FOUT/.code') == 404 ]] && jq -e '.error == \"mcp_rejected\" and .hold == \"scan_policy\"' '$FOUT/.body' >/dev/null"
call admin GET "/api/v1/repositories/mcp-internal/mcp/servers/com.acme/tickets/versions/1.0.2/health" > "$GOUT/g6-health.json"
check $G "its health names the finding (injection_phrase, action review)" "see log" \
  jq -e 'any(.lint.findings[]; .rule == "injection_phrase" and .action == "review")' "$GOUT/g6-health.json"
