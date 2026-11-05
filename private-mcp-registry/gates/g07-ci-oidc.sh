#!/usr/bin/env bash
# G7 Publishing from CI: the github-oidc exchange, the issuer-bound namespace grant, and
# mcp_require_namespace_grant.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G7 V="2.$RUNID.0"
x() { call - POST "/mcp/mcp-internal/v0/auth/github-oidc" -d "$(jq -nc --arg t "$1" '{oidc_token: $t}')"; }
x "$("$ROOT/ci/lab-issuer.sh" mint)" > "$GOUT/g7-x.json"
check $G "an acme main-branch ID token is exchanged for a registry token (200)" "$(why)" jq -e '.registry_token | length > 20' "$GOUT/g7-x.json"
T=$(jq -r .registry_token "$GOUT/g7-x.json")
pubt() { akcurl -sS -o "$FOUT/.body" -w '%{http_code}' -X POST -H "Authorization: Bearer $T" "$U$REG/publish" \
  -d "$(jq -nc --arg s "$SCHEMA" --arg n "$1" --arg v "$V" '{"$schema": $s, name: $n, description: "gate", version: $v,
        remotes: [{type: "streamable-http", url: "https://status.acme.example/mcp"}]}')" > "$FOUT/.code"; why; }
pubt com.acme/status
check $G "the exchanged token publishes com.acme/status (inside com.{repository_owner}/*)" "$(why)" is 200
pubt com.acme.payments/ledger
check $G "it cannot publish com.acme.payments/ledger (403 mcp_namespace_not_granted)" "$(why)" is 403 mcp_namespace_not_granted
x "$("$ROOT/ci/lab-issuer.sh" mint repository_owner=evil)" >/dev/null
check $G "another organization's ID token is refused (401 mcp_unauthorized)" "$(why)" is 401 mcp_unauthorized
x "$("$ROOT/ci/lab-issuer.sh" mint aud=https://other.example)" >/dev/null
check $G "an ID token for another audience is refused (401)" "$(why)" is 401
call admin PATCH /api/v1/repositories/mcp-internal -d '{"mcp_require_namespace_grant":true}' >/dev/null
call ci POST "$REG/publish" -d "$(jq -nc --arg s "$SCHEMA" --arg v "$V" '{"$schema": $s, name: "com.acme/gate-ci", description: "gate", version: $v,
  remotes: [{type: "streamable-http", url: "https://gate.acme.example/mcp"}]}')" >/dev/null; why
check $G "with mcp_require_namespace_grant, repository write alone (the ci user) is refused (403 mcp_namespace_not_granted)" "$(why)" is 403 mcp_namespace_not_granted
V="3.$RUNID.0"; pubt com.acme/status
check $G "... while the namespace-granted CI account still publishes" "$(why)" is 200
call admin PATCH /api/v1/repositories/mcp-internal -d '{"mcp_require_namespace_grant":false}' >/dev/null
