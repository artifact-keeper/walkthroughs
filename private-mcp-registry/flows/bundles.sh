#!/usr/bin/env bash
# Step 7 (optional): MCPB bundles with a trusted signer, and capability snapshots.
#   - mcp-internal requires signed bundles (mcp_require_bundle_signature); the backend trusts
#     the lab signer's certificate fingerprint (MCP_TRUSTED_BUNDLE_SIGNERS, set by up.sh)
#   - the mcpb CLI (npm @anthropic-ai/mcpb, installed through ak.internal/npm/npm) packs the
#     server and signs it: unsigned and self-signed bundles are refused, the signed one is
#     stored, and com.acme/tickets-desktop 1.0.0 is published with it
#   - an exact read hands out a single-use download ticket; a listing does not
#   - capability snapshots: the declared tools, two CI reports, the diff and tool_drift
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NAME=com.acme/tickets-desktop V=1.0.0
B="$REG/servers/$(enc $NAME)/versions/$V/bundles/acme-tickets.mcpb"

say "Require signed bundles on mcp-internal"
call admin PATCH /api/v1/repositories/mcp-internal -d '{"mcp_require_bundle_signature":true}' | jq -c '{mcp_require_bundle_signature}'

say "Pack and sign with the mcpb CLI (unsigned, self-signed, and signed by the trusted lab signer)"
mkdir -p "$ROOT/out/bundles"
"$RUN" -t ci -v "$REG_DIR/.signer:/signer:ro,z" -- bash -c "set -e; $NPMRC
  mcpb() { npx -y --registry https://ak.internal/npm/npm/ @anthropic-ai/mcpb@2.1.2 \"\$@\"; }
  mkdir -p /tmp/b/server && cd /tmp/b && cp /servers/acme-tickets/bundle/manifest.json .
  sed 's#require(.\\.\\./package.json.)#{ version: \"$V\" }#' /servers/acme-tickets/bin/server.js > server/index.js
  mcpb pack . /out/bundles/unsigned.mcpb | tail -1
  cp /out/bundles/unsigned.mcpb /tmp/self.mcpb && (cd /tmp && mcpb sign --self-signed --cert /tmp/other.crt --key /tmp/other.key self.mcpb)
  cp /tmp/self.mcpb /out/bundles/self-signed.mcpb
  cp /out/bundles/unsigned.mcpb /out/bundles/acme-tickets.mcpb
  mcpb sign --cert /signer/signer.crt --key /signer/signer.key /out/bundles/acme-tickets.mcpb"
for f in unsigned self-signed; do
  echo "-- upload $f.mcpb:"; show ci PUT "$B" --data-binary "@$ROOT/out/bundles/$f.mcpb"
done
echo "-- upload acme-tickets.mcpb (signed by the trusted signer):"
up=$(call ci PUT "$B" --data-binary "@$ROOT/out/bundles/acme-tickets.mcpb")
echo "HTTP $(code)"; jq -c '{file, fileSha256, signature: .signature | {state, signer, fingerprint}, packageEntry}' <<<"$up"

say "Publish $NAME $V with the bundle's package entry"
entry=$(jq -c .packageEntry <<<"$up")
if [[ $entry == null ]]; then entry=$(call ci GET "$REG/servers/$(enc $NAME)/versions/$V" | jq -c '.server.packages[0] | .identifier |= sub("\\?ticket=.*$"; "")'); fi
call ci POST "$REG/publish" -d "$(jq -nc --arg s "$SCHEMA" --arg n "$NAME" --arg v "$V" --argjson p "$entry" \
  '{"$schema": $s, name: $n, title: "Acme tickets (desktop bundle)",
    description: "Read-only access to Acme tickets, as a one-click MCPB bundle", version: $v, packages: [$p]}')" >/dev/null
echo "publish: HTTP $(code)"

say "An exact read carries a single-use download ticket; a listing does not"
url=$(call developer GET "$REG/servers/$(enc $NAME)/versions/$V" | jq -r '.server.packages[0].identifier')
sed -E 's/ticket=[^&]+/ticket=<redacted>/' <<<"$url"
call developer GET "$REG/servers?search=desktop" | jq -r '.servers[0].server.packages[0].identifier'
h=${url/https:\/\/ak.internal/$U}
echo "-- download with the ticket and no credential:"
akcurl -sS -o "$ROOT/out/bundles/downloaded.mcpb" -D - "$h" | grep -iE '^(HTTP|x-checksum-sha256|cache-control)' | tr -d '\r'
echo "sha256 of the download: $(sha256sum "$ROOT/out/bundles/downloaded.mcpb" | cut -d' ' -f1)"
echo "-- the same ticket again: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' "$h")"

say "Capabilities: what the bundle's manifest declares"
call developer GET "$REG/servers/$(enc $NAME)/versions/$V/capabilities" \
  | jq -c '{current: .current | {source, provenance, tools: [.tools[].name]}, notice}'

say "Capabilities: CI reports what tools/list returned for com.acme/tickets 1.0.0, twice"
C="$REG/servers/$(enc com.acme/tickets)/versions/1.0.0/capabilities"
tools=$("$RUN" -t developer -- bash -c "$NPMRC
  mcp-call - '{}' -- $(cat "$ROOT/out/clients/tickets-command.txt")" | jq -c .toolList)
call ci POST "$C" -d "$(jq -nc --argjson t "$tools" '{source: "ci_reported", generatedBy: "tools/list in CI", tools: $t}')" \
  | jq -c '{source: .snapshot.source, provenance: .snapshot.provenance, tools: .snapshot.counts.tools, drift}'
more=$(jq -c '. + [{name: "close_ticket", description: "Close a ticket", inputSchema: {type: "object"}, annotations: {destructiveHint: true}}]' <<<"$tools")
call ci POST "$C" -d "$(jq -nc --argjson t "$more" '{source: "ci_reported", generatedBy: "tools/list in CI", tools: $t}')" \
  | jq -c '{source: .snapshot.source, tools: .snapshot.counts.tools, drift}'
call developer GET "$C/diff?source=ci_reported" | jq -c '{summary: .summary.text, destructiveAdded: .summary.destructiveAdded}'
call admin GET "/api/v1/security/artifacts/$(call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/1.0.0" \
  | jq -r '._meta["com.artifactkeeper.registry/source"].artifactId')/scans" \
  | jq -c '(if type == "array" then . else .items end)[] | {scan_type, scanner: (.scanner_version // .scanner), findings: (.findings_count // .total_findings)}' | head -4
