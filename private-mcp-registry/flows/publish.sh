#!/usr/bin/env bash
# Step 2: publish Acme's internal MCP server, com.acme/tickets 1.0.0, as a CI job would.
#   1. the code: npm publish @acme/tickets-mcp@1.0.0 to npm-internal (ci token)
#   2. the image: podman build on the host, then skopeo copy to ak.internal/oci-internal
#   3. the registry entry: POST /validate (curl), then mcp-publisher publish (ci token)
# A step that is already done (the version exists) is skipped: versions are immutable.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
V=1.0.0

say "1. npm publish @acme/tickets-mcp@$V to npm-internal"
if call ci GET "/npm/npm-internal/@acme%2Ftickets-mcp" >/dev/null && [[ $(code) == 200 ]] \
   && jq -e --arg v "$V" '.versions[$v]' "$FOUT/.body" >/dev/null; then
  echo "@acme/tickets-mcp@$V is already in npm-internal: skipped"
else
  "$RUN" -t ci -- bash -c "set -eo pipefail; $NPMRC
    cp -r /servers/acme-tickets /tmp/p && cd /tmp/p
    npm publish --registry https://ak.internal/npm/npm-internal/ 2>&1 | grep -vE '^npm notice *$|New major version|Changelog|To update run'"
fi

say "2. build the image and push it to ak.internal/oci-internal/acme/tickets-mcp:$V"
mkdir -p "$ROOT/out/images"
podman build -q -t "localhost/ak-mcp/tickets-mcp:$V" "$ROOT/servers/acme-tickets" >/dev/null
podman save --format oci-archive -o "$ROOT/out/images/tickets-mcp-$V.tar" "localhost/ak-mcp/tickets-mcp:$V"
"$RUN" -t ci -- bash -c "set -e
  if skopeo inspect --creds ci:\$AK_TOKEN docker://ak.internal/oci-internal/acme/tickets-mcp:$V >/dev/null 2>&1; then
    echo 'acme/tickets-mcp:$V is already in oci-internal: skipped'
  else
    skopeo copy -q --dest-creds ci:\$AK_TOKEN oci-archive:/out/images/tickets-mcp-$V.tar docker://ak.internal/oci-internal/acme/tickets-mcp:$V
  fi
  skopeo inspect --creds ci:\$AK_TOKEN docker://ak.internal/oci-internal/acme/tickets-mcp:$V \
    | jq -c '{Digest, label: .Labels[\"io.modelcontextprotocol.server.name\"]}'"

say "3a. POST $REG/validate: what a publish would do, without writing anything"
show ci POST "$REG/validate" --data-binary "@$ROOT/servers/acme-tickets/server.json"
# A CI job should stop here unless every package is already pinned: `fill` would mean a package
# is missing from the registry and would be looked for upstream.
if ! jq -e '.valid and all(.packages[]; .outcome == "pinned")' "$FOUT/.body" >/dev/null; then
  echo "publish.sh: /validate did not pin every package; not publishing" >&2; exit 1
fi

say "3b. mcp-publisher publish (token.json written by hand with the ci token)"
call ci GET "$REG/servers/$(enc com.acme/tickets)/versions/$V" >/dev/null
if [[ $(code) == 200 ]]; then echo "com.acme/tickets@$V is already published: skipped"; else
  "$RUN" -t ci -- bash -c '
    mkdir -p ~/.config/mcp-publisher
    jq -n --arg t "$AK_TOKEN" "{token: \$t, method: \"none\", registry: \"https://ak.internal/mcp/mcp-internal\"}" \
      > ~/.config/mcp-publisher/token.json
    cd /servers/acme-tickets && mcp-publisher publish' | tee "$FOUT/publish-tickets.txt"
fi

say "What the registry serves for com.acme/tickets $V (developer token)"
call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/latest" | tee "$FOUT/tickets-latest.json" \
  | jq '{name: .server.name, version: .server.version,
         packages: [.server.packages[] | {registryType, identifier, version, registryBaseUrl}],
         source: ._meta["com.artifactkeeper.registry/source"] | {repository, origin, packagePolicy}}'
