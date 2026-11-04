#!/usr/bin/env bash
# Step 5: publish from CI with GitHub Actions OIDC, no stored token.
#   - a CI OIDC provider for https://token.actions.githubusercontent.com, audience
#     https://ak.internal, with the lab issuer's key (key_source static: Artifact Keeper never
#     contacts the issuer); a mapping for repository_owner=acme on refs/heads/main
#   - a namespace grant: the mapping's account may write com.{repository_owner}/* to
#     mcp-internal, with the claim bound to GitHub's issuer
#   - in the workstation, the environment GitHub Actions gives a job with id-token: write
#     (ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN), served by a stand-in token endpoint, then
#     `mcp-publisher login github-oidc` and `mcp-publisher publish`
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ISS=https://token.actions.githubusercontent.com

say "The CI OIDC provider (static JWKS of the lab issuer) and the mapping"
pid=$(call admin GET /api/v1/admin/ci-oidc | jq -r --arg i "$ISS" '(if type == "array" then . else .items end)[] | select(.issuer_url == $i) | .id' | head -1)
if [[ -z $pid ]]; then
  jwks=$("$ROOT/ci/lab-issuer.sh" keys)
  pid=$(call admin POST /api/v1/admin/ci-oidc -d "$(jq -nc --arg i "$ISS" --argjson j "$jwks" \
    '{name: "github-actions", provider_type: "github", issuer_url: $i, audience: "https://ak.internal",
      key_source: "static", static_jwks: $j, token_ttl_secs: 900}')" | jq -r .id)
fi
call admin GET "/api/v1/admin/ci-oidc/$pid" | jq -c '{id, name, issuer_url, audience, key_source, token_ttl_secs}'
map=$(call admin GET "/api/v1/admin/ci-oidc/$pid/mappings" | jq -c '(if type == "array" then . else .items end)[] | select(.name == "acme-mcp-publish")' | head -1)
if [[ -z $map ]]; then
  map=$(call admin POST "/api/v1/admin/ci-oidc/$pid/mappings" \
    -d '{"name":"acme-mcp-publish","claim_filters":{"repository_owner":"acme","ref":"refs/heads/main"}}')
fi
jq -c '{name, claim_filters, service_account_id, service_account_username}' <<<"$map"
sa=$(jq -r .service_account_id <<<"$map")

say "The namespace grant: write com.{repository_owner}/* on mcp-internal, claims from $ISS only"
rid=$(repo_id mcp-internal)
have=$(call admin GET "/api/v1/permissions?per_page=500" | jq -r --arg u "$sa" --arg r "$rid" \
  '(if type == "array" then . else .items end)[] | select(.principal_id == $u and .target_id == $r) | .id' | head -1)
if [[ -z $have ]]; then
  echo "-- without the issuer binding:"
  show admin POST /api/v1/permissions -d "$(jq -nc --arg u "$sa" --arg r "$rid" '{principal_type: "user", principal_id: $u,
    target_type: "repository", target_id: $r, actions: ["write"], conditions: {mcp_namespaces: ["com.{repository_owner}/*"]}}')"
  echo "-- with it:"
  show admin POST /api/v1/permissions -d "$(jq -nc --arg u "$sa" --arg r "$rid" --arg i "$ISS" '{principal_type: "user", principal_id: $u,
    target_type: "repository", target_id: $r, actions: ["write"],
    conditions: {mcp_namespaces: ["com.{repository_owner}/*"], mcp_namespace_issuer: $i}}')"
else
  call admin GET "/api/v1/permissions?per_page=500" | jq -c --arg id "$have" '(if type == "array" then . else .items end)[] | select(.id == $id) | {actions, conditions}'
fi

# One job run: the ID token the job would get, a stand-in for the Actions token endpoint, the
# publisher. NAME and VERSION are the server.json the job publishes (com.acme/status 2.0.0).
job() { # NAME VERSION [claim=value ...]
  local name=$1 version=$2; shift 2
  ID_TOKEN=$("$ROOT/ci/lab-issuer.sh" mint "$@") NAME=$name VERSION=$version \
  "$RUN" -h ci-job -e ID_TOKEN -e NAME -e VERSION -- bash -c '
    rm -rf ~/.config/mcp-publisher
    node -e "require(\"http\").createServer((q, s) => { console.error(\"token endpoint: GET \" + q.url);
      s.setHeader(\"Content-Type\", \"application/json\"); s.end(JSON.stringify({value: process.env.ID_TOKEN})); })
      .listen(8099, \"127.0.0.1\")" & sleep 1
    export ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:8099/token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=lab-request-token
    mkdir -p /tmp/job && cd /tmp/job
    jq -n --arg n "$NAME" --arg v "$VERSION" "{\"\$schema\": \"https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json\",
      name: \$n, title: \"Acme status\", description: \"Service status for Acme systems\", version: \$v,
      remotes: [{type: \"streamable-http\", url: \"https://status.acme.example/mcp\"}]}" > server.json
    echo "\$ mcp-publisher login github-oidc --registry https://ak.internal/mcp/mcp-internal"
    mcp-publisher login github-oidc --registry https://ak.internal/mcp/mcp-internal 2>&1 || exit 0
    echo "\$ mcp-publisher publish   # $NAME@$VERSION"
    mcp-publisher publish 2>&1; echo "exit $?"'
}

say "Job 1: acme/tickets-mcp on main publishes com.acme/status 2.0.0"
job com.acme/status 2.0.0 | tee "$FOUT/ci-job-1.txt"
say "Job 2: the same job tries com.acme.payments/ledger 1.0.0 (outside com.acme/*)"
job com.acme.payments/ledger 1.0.0 | tee "$FOUT/ci-job-2.txt"
say "Job 3: a workflow in another organization (repository_owner=evil)"
job com.acme/status 2.0.1 repository_owner=evil sub=repo:evil/tickets-mcp:ref:refs/heads/main repository=evil/tickets-mcp | tee "$FOUT/ci-job-3.txt"
say "Job 4: acme's workflow on a feature branch (ref=refs/heads/feature)"
job com.acme/status 2.0.1 ref=refs/heads/feature | tee "$FOUT/ci-job-4.txt"

say "Who published what"
call developer GET "$REG/servers/$(enc com.acme/status)/versions/latest" | jq -c '{name: .server.name, version: .server.version}'
audit '^(MCP_SERVER_PUBLISHED|MCP_NAMESPACE_GRANTED)$' 100 | grep -E 'com.acme/status|MCP_NAMESPACE_GRANTED' | head -3
