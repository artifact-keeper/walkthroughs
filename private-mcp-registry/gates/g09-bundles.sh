#!/usr/bin/env bash
# G9 Bundles and capabilities: only trusted signers, single-use tickets, tool diffs.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G9 V="0.$RUNID.0"
B="$REG/servers/$(enc com.acme/tickets-gate)/versions/$V/bundles/acme-tickets.mcpb"
call ci PUT "$B" --data-binary "@$ROOT/out/bundles/unsigned.mcpb" >/dev/null; why
check $G "an unsigned bundle is 422 mcp_bundle_unsigned" "$(why)" is 422 mcp_bundle_unsigned
call ci PUT "$B" --data-binary "@$ROOT/out/bundles/self-signed.mcpb" >/dev/null; why
check $G "a bundle signed by an unknown certificate is 422 mcp_bundle_signer_untrusted" "$(why)" is 422 mcp_bundle_signer_untrusted
cp "$ROOT/out/bundles/acme-tickets.mcpb" "$GOUT/tampered.mcpb"
python3 -I -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[40]^=0xFF; open(p,"wb").write(b)' "$GOUT/tampered.mcpb"
call ci PUT "$B" --data-binary "@$GOUT/tampered.mcpb" >/dev/null; why
check $G "a signed bundle changed after signing is refused (422 or 400)" "$(why)" bash -c "[[ \$(cat '$FOUT/.code') =~ ^4(22|00)$ ]]"
call developer GET "$REG/servers/$(enc com.acme/tickets-desktop)/versions/1.0.0" > "$GOUT/g9-desktop.json"
url=$(jq -r '.server.packages[0].identifier' "$GOUT/g9-desktop.json")
check $G "an exact read of the bundle version carries a ticket" "no ticket" bash -c "[[ '$url' == *'?ticket='* ]]"
h=${url/https:\/\/ak.internal/$U}
c1=$(akcurl -sS -o "$GOUT/g9.mcpb" -w '%{http_code}' "$h"); c2=$(akcurl -sS -o /dev/null -w '%{http_code}' "$h")
check $G "the ticket downloads the signed bytes once without a credential, then not again" "first $c1, second $c2" \
  bash -c "[[ $c1 == 200 && $c2 != 200 ]] && cmp -s '$GOUT/g9.mcpb' '$ROOT/out/bundles/acme-tickets.mcpb'"
call developer GET "$REG/servers/$(enc com.acme/tickets)/versions/1.0.0/capabilities/diff?source=ci_reported" > "$GOUT/g9-diff.json"
check $G "the capabilities diff of the CI reports shows the added destructive tool" "see log" \
  jq -e '.summary.destructiveAdded == ["close_ticket"]' "$GOUT/g9-diff.json"
