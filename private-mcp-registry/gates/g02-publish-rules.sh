#!/usr/bin/env bash
# G2 Publish rules on mcp-internal: versions are write-once, names stay in com.acme, packages
# must come from this Artifact Keeper and be pinned, and the lint refuses secrets.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G2 V="0.$RUNID.0"
doc() { jq -nc --arg s "$SCHEMA" --arg n "$1" --arg v "$V" --argjson x "$2" '{"$schema": $s, name: $n, description: "gate", version: $v} + $x'; }
REM='{"remotes":[{"type":"streamable-http","url":"https://gate.acme.example/mcp"}]}'
pub() { call ci POST "$REG/publish" -d "$1" >/dev/null; why; }
call ci POST "$REG/publish" --data-binary "@$ROOT/servers/acme-tickets/server.json" >/dev/null; why
check $G "republishing com.acme/tickets 1.0.0 is 409 mcp_version_exists" "$(why)" is 409 mcp_version_exists
pub "$(doc io.github.someone/tickets "$REM")"
check $G "a name outside com.acme is 403 mcp_namespace_not_allowed" "$(why)" is 403 mcp_namespace_not_allowed
pub "$(doc io.modelcontextprotocol/tickets "$REM")"
check $G "the reserved io.modelcontextprotocol namespace is 403" "$(why)" is 403
pub "$(doc com.acme/gate '{"packages":[{"registryType":"npm","registryBaseUrl":"https://registry.npmjs.org","identifier":"left-pad","version":"1.3.0","transport":{"type":"stdio"}}]}')"
check $G "an npm package from registry.npmjs.org is 422 mcp_external_registry" "$(why)" is 422 mcp_external_registry
pub "$(doc com.acme/gate '{"packages":[{"registryType":"oci","identifier":"docker.io/mcp/fetch:1.0.0","transport":{"type":"stdio"}}]}')"
check $G "an image on Docker Hub is 422 mcp_external_registry" "$(why)" is 422 mcp_external_registry
pub "$(doc com.acme/gate '{"packages":[{"registryType":"oci","identifier":"ak.internal/oci-internal/acme/tickets-mcp:latest","transport":{"type":"stdio"}}]}')"
check $G "a floating image tag is 422 mcp_oci_floating_tag" "$(why)" is 422 mcp_oci_floating_tag
pub "$(doc com.acme/gate '{"packages":[{"registryType":"oci","identifier":"ak.internal/oci-internal/acme/tickets-mcp:9.9.9","transport":{"type":"stdio"}}]}')"
check $G "an image tag that was never pushed is 422 mcp_package_not_found" "$(why)" is 422 mcp_package_not_found
pub "$(doc com.acme/gate '{"packages":[{"registryType":"npm","identifier":"@acme/tickets-mcp","transport":{"type":"stdio"}}]}')"
check $G "an npm package without a version is 422 mcp_package_version_unpinned" "$(why)" is 422 mcp_package_version_unpinned
fake="ghp_$(openssl rand -hex 18)"
pub "$(doc com.acme/gate "$(jq -nc --arg t "$fake" '{remotes:[{type:"streamable-http",url:"https://gate.acme.example/mcp",headers:[{name:"Authorization",value:("Bearer "+$t)}]}]}')")"
check $G "a hardcoded GitHub token is 422 mcp_lint_blocked (rule secret_literal)" "$(why)" \
  bash -c "[[ $(code) == 422 ]] && jq -e '.error == \"mcp_lint_blocked\" and any(.findings[]; .rule == \"secret_literal\")' '$FOUT/.body' >/dev/null"
check $G "the refusal does not echo the secret" "the token appears in the body" bash -c "! grep -q '$fake' '$FOUT/.body'"
