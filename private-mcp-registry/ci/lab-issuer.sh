#!/usr/bin/env bash
# A stand-in for GitHub's OIDC issuer, for the lab only.
#   ci/lab-issuer.sh keys            create the signing key (out/ci/issuer.key) and print the
#                                    JWKS Artifact Keeper is given (static key source)
#   ci/lab-issuer.sh mint KEY=VALUE  print a signed ID token with GitHub Actions' claims; each
#                                    KEY=VALUE overrides a claim (repository_owner=evil)
# The token carries iss=https://token.actions.githubusercontent.com and aud=https://ak.internal,
# exactly what a workflow with `permissions: id-token: write` receives when mcp-publisher asks
# for the registry's audience. It is signed with a key made here, not GitHub's: Artifact Keeper
# trusts it only because the provider stores this key's JWKS (key_source: static).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$here/../out/ci"; mkdir -p "$D"; KEY="$D/issuer.key"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
case "${1:-}" in
  keys)
    [[ -s $KEY ]] || (umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY" 2>/dev/null)
    n=$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | cut -d= -f2 | python3 -I -c 'import sys,binascii; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().strip()))' | b64url)
    jq -nc --arg n "$n" '{keys: [{kty: "RSA", kid: "lab-github-actions-1", use: "sig", alg: "RS256", n: $n, e: "AQAB"}]}'
    ;;
  mint)
    shift
    now=$(date +%s)
    claims=$(jq -nc --argjson now "$now" '{
      iss: "https://token.actions.githubusercontent.com", aud: "https://ak.internal",
      sub: "repo:acme/tickets-mcp:ref:refs/heads/main", repository: "acme/tickets-mcp",
      repository_owner: "acme", repository_owner_id: "1001", repository_id: "2002",
      ref: "refs/heads/main", ref_type: "branch", event_name: "push", actor: "release-bot",
      workflow: "publish", job_workflow_ref: "acme/tickets-mcp/.github/workflows/publish.yml@refs/heads/main",
      runner_environment: "github-hosted", jti: ("lab-" + ($now|tostring)),
      iat: $now, nbf: ($now - 5), exp: ($now + 300)}')
    for kv in "$@"; do claims=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$claims"); done
    h=$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"lab-github-actions-1"}' | b64url)
    p=$(printf '%s' "$claims" | b64url)
    s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$KEY" -binary | b64url)
    printf '%s.%s.%s\n' "$h" "$p" "$s"
    ;;
  *) echo "usage: ci/lab-issuer.sh keys | mint [claim=value ...]" >&2; exit 2 ;;
esac
