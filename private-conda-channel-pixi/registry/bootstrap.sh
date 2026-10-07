#!/usr/bin/env bash
# Idempotently configure the ak-conda registry for the walkthrough:
#   - repositories: conda-forge (remote), conda-internal (hosted, internal,
#     promotion-only), conda-staging (staging, private, release target
#     conda-internal), conda-virtual (virtual: internal p1, forge p2),
#     pypi-remote, oci-apps, oci-ghcr + oci-redhat (image proxies), trust (generic, public)
#   - tokens (in registry/.tokens/, gitignored, mode 600):
#       ci.token            repo token on conda-staging, read+write
#       consumer.token      user API token (user "consumer"), read:artifacts,
#                           repo_selector = the four consumer repos
#       consumer-repo.token repo token on conda-virtual, read only (kept to
#                           show what a single repo token can and cannot do)
#       ci-oci.token        repo token on oci-apps, read+write (image push)
#     plus podman auth files consumer-podman.json / ci-podman.json and rattler/pixi auth files ci-auth.json and consumer-auth.json
#     ({"ak.internal": {"BearerToken": ...}}), the RATTLER_AUTH_FILE format.
#   - uploads the internal CA to trust/ak-internal-ca.crt
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
command -v jq >/dev/null || { echo "bootstrap.sh: jq is required" >&2; exit 1; }
U="$(AK_HOST_URL)"
log() { echo "bootstrap: $*"; }
mkdir -p "$TOKENS" "$OUT"; chmod 700 "$TOKENS"

akcurl -fsS "$U/readyz" >/dev/null || { echo "bootstrap.sh: $U/readyz not ready" >&2; exit 1; }

# Reuse the admin API token if it still works; otherwise log in once and mint one.
if [[ -s "$TOKENS/admin.token" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $(<"$TOKENS/admin.token")" "$U/api/v1/auth/me") == 200 ]]; then
  JWT=$(<"$TOKENS/admin.token"); log "using admin.token"
else
  JWT=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg p "$ADMIN_PASSWORD" '{username:"admin",password:$p}')" | jq -r .access_token)
  [[ -n "$JWT" && "$JWT" != null ]] || { echo "bootstrap.sh: admin login failed" >&2; exit 1; }
  log "logged in as admin"
  (umask 077; akcurl -fsS -X POST "$U/api/v1/auth/tokens" -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
     -d '{"name":"walkthrough-admin","scopes":["*"],"expires_in_days":30}' | jq -r .token > "$TOKENS/admin.token")
  log "minted admin.token (scopes *, 30 days) for the other scripts"
fi

api() { # api METHOD PATH [curl args...]  -> body, then HTTP code on the last line
  local m=$1 p=$2; shift 2
  akcurl -sS -X "$m" "$U/api/v1$p" -H "Authorization: Bearer $JWT" \
       -H 'Content-Type: application/json' -w '\n%{http_code}' "$@"
}
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }

# --- repositories -------------------------------------------------------------
create_repo() { # key json
  local key=$1 body=$2 r
  r=$(api GET "/repositories/$key")
  if [[ $(code_of "$r") == 200 ]]; then log "repo $key exists"; return; fi
  r=$(api POST /repositories -d "$body")
  if [[ $(code_of "$r") =~ ^20 ]]; then
    log "repo $key created: $(body_of "$r" | jq -c '{format,repo_type,visibility,upstream_url}')"
  else
    echo "bootstrap.sh: creating $key failed: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1
  fi
}
create_repo conda-forge '{"key":"conda-forge","name":"conda-forge (proxy)","format":"conda","repo_type":"remote","visibility":"internal","upstream_url":"https://conda.anaconda.org/conda-forge"}'
create_repo conda-internal '{"key":"conda-internal","name":"Internal conda packages (released)","format":"conda","repo_type":"local","visibility":"internal","promotion_only":true}'
create_repo conda-staging '{"key":"conda-staging","name":"Internal conda packages (staging, CI publishes here)","format":"conda","repo_type":"staging","visibility":"private"}'
create_repo conda-virtual '{"key":"conda-virtual","name":"conda (internal first, then conda-forge)","format":"conda","repo_type":"virtual","visibility":"internal","member_repos":[{"repo_key":"conda-internal","priority":1},{"repo_key":"conda-forge","priority":2}]}'
create_repo pypi-remote '{"key":"pypi-remote","name":"PyPI (proxy)","format":"pypi","repo_type":"remote","visibility":"internal","upstream_url":"https://pypi.org"}'
create_repo oci-apps '{"key":"oci-apps","name":"Application images","format":"docker","repo_type":"local","visibility":"internal"}'
# Container base images also come through the registry (pulled by the host's
# podman at localhost:30444, see image/README.md).
create_repo oci-ghcr '{"key":"oci-ghcr","name":"ghcr.io (proxy)","format":"docker","repo_type":"remote","visibility":"internal","upstream_url":"https://ghcr.io"}'
create_repo oci-redhat '{"key":"oci-redhat","name":"registry.access.redhat.com (proxy)","format":"docker","repo_type":"remote","visibility":"internal","upstream_url":"https://registry.access.redhat.com"}'
create_repo trust '{"key":"trust","name":"Trust anchors: CA certificate, verification keys, SBOMs","format":"generic","repo_type":"local","visibility":"public"}'

r=$(api PUT /promotion/repositories/conda-staging/release-target -d '{"release_repository_key":"conda-internal"}')
log "conda-staging release target -> conda-internal: HTTP $(code_of "$r")"

# --- hosted scanning: scan every upload to staging and internal ----------------
for k in conda-staging conda-internal; do
  r=$(api PUT "/repositories/$k/security" -d '{"scan_enabled":true,"scan_on_upload":true}')
  log "scan-on-upload $k: HTTP $(code_of "$r")"
done

# --- promotion gate: scan policy on conda-staging ----------------------------------
# Promotion out of conda-staging evaluates the policy attached to the SOURCE repo:
# a verified CEP-27 attestation, no high/critical findings, a completed scan,
# and no denied license.
sid=$(body_of "$(api GET /repositories/conda-staging)" | jq -r .id)
pol=$(body_of "$(api GET /security/policies)" | jq -r '(if type=="array" then . else .items end)[] | select(.name=="conda-release-gate") | .id' | head -1 2>/dev/null || true)
if [[ -n "$pol" ]]; then log "policy conda-release-gate exists ($pol)"; else
  r=$(api POST /security/policies -d "$(jq -nc --arg rid "$sid" '{name:"conda-release-gate",repository_id:$rid,
        max_severity:"high",block_unscanned:true,block_on_fail:true,require_signature:false,
        predicates:{conda:{min_attestation_state:"verified",
                           denied_license_families:["GPL","AGPL","LGPL"],
                           denied_licenses:["GPL-3.0-only","GPL-3.0-or-later","AGPL-3.0-only"],
                           block_install_scripts:true}}}')")
  [[ $(code_of "$r") =~ ^20 ]] || { echo "bootstrap.sh: policy failed: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
  log "policy conda-release-gate created on conda-staging: $(body_of "$r" | jq -c '{max_severity,block_unscanned,predicates}')"
fi

# --- tokens -------------------------------------------------------------------
works() { # token path -> 0 if GET path is 200 with the token
  [[ -s "$1" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$1")" "$U$2") == 200 ]]
}
auth_file() { # token-file auth-file
  jq -n --arg h "$AK_HOST" --arg t "$(cat "$1")" '{($h): {BearerToken: $t}}' > "$2"; chmod 600 "$2"
}
mint_repo_token() { # repo name scopes-json out
  local r
  r=$(api POST "/repositories/$1/tokens" -d "$(jq -nc --arg n "$2" --argjson s "$3" '{name:$n,scopes:$s,expires_in_days:90}')")
  [[ $(code_of "$r") =~ ^20 ]] || { echo "bootstrap.sh: repo token on $1 failed: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
  (umask 077; body_of "$r" | jq -r .token > "$4")
}

if works "$TOKENS/ci.token" /api/v1/auth/me; then log "ci.token still valid"; else
  mint_repo_token conda-staging ci-publish '["read:artifacts","write:artifacts"]' "$TOKENS/ci.token"
  log "minted ci.token (repo token on conda-staging: read+write, 90 days)"
fi
auth_file "$TOKENS/ci.token" "$TOKENS/ci-auth.json"

if works "$TOKENS/consumer-repo.token" /api/v1/auth/me; then log "consumer-repo.token still valid"; else
  mint_repo_token conda-virtual consumer-virtual-ro '["read:artifacts"]' "$TOKENS/consumer-repo.token"
  log "minted consumer-repo.token (repo token on conda-virtual: read only)"
fi

# The consumer: a non-admin user whose token reads exactly the consumer repos.
CONSUMER_PW_FILE="$TOKENS/consumer.password"
r=$(api GET "/users?per_page=200")
uid=$(body_of "$r" | jq -r '(if type=="array" then . else .items end)[] | select(.username=="consumer") | .id' 2>/dev/null || true)
if [[ -z "$uid" ]]; then
  (umask 077; echo "Ck$(openssl rand -hex 16)" > "$CONSUMER_PW_FILE")
  r=$(api POST /users -d "$(jq -nc --arg p "$(cat "$CONSUMER_PW_FILE")" \
      '{username:"consumer",email:"consumer@ak.internal",password:$p,display_name:"Build consumer (read only)",is_admin:false}')")
  [[ $(code_of "$r") =~ ^20 ]] || { echo "bootstrap.sh: create user consumer failed: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
  uid=$(body_of "$r" | jq -r '.user.id // .id')
  log "created user consumer ($uid)"
fi
if works "$TOKENS/consumer.token" /api/v1/auth/me; then log "consumer.token still valid"; else
  ids=$(for k in conda-virtual conda-internal conda-forge pypi-remote oci-ghcr oci-redhat; do
          body_of "$(api GET "/repositories/$k")" | jq -r .id; done | jq -R . | jq -sc .)
  # Minted by the consumer itself: POST /users/{id}/tokens (admin minting for
  # another user) rejects repo_selector on this build; /auth/tokens accepts it.
  CJWT=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg p "$(cat "$CONSUMER_PW_FILE")" '{username:"consumer",password:$p}')" | jq -r .access_token)
  r=$(akcurl -sS -X POST "$U/api/v1/auth/tokens" -H "Authorization: Bearer $CJWT" -H 'Content-Type: application/json' \
      -w '\n%{http_code}' -d "$(jq -nc --argjson ids "$ids" \
      '{name:"consumer-read",scopes:["read:artifacts"],expires_in_days:90,repo_selector:{match_repos:$ids}}')")
  [[ $(code_of "$r") =~ ^20 ]] || { echo "bootstrap.sh: consumer token failed: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
  (umask 077; body_of "$r" | jq -r .token > "$TOKENS/consumer.token")
  log "minted consumer.token (user consumer, read:artifacts, selector: conda-virtual conda-internal conda-forge pypi-remote oci-ghcr oci-redhat)"
fi
auth_file "$TOKENS/consumer.token" "$TOKENS/consumer-auth.json"

if works "$TOKENS/ci-oci.token" /api/v1/auth/me; then log "ci-oci.token still valid"; else
  mint_repo_token oci-apps ci-oci-push '["read:artifacts","write:artifacts"]' "$TOKENS/ci-oci.token"
  log "minted ci-oci.token (repo token on oci-apps: read+write)"
fi

# --- podman access from the host (image pulls and pushes) ---------------------
# The host's podman cannot resolve ak.internal; it uses the loopback port by the
# name localhost, for which Caddy issues a DNS:localhost certificate from the
# same internal CA.
CERTS="$OUT/certs.d/localhost:${HTTPS_PORT}"
mkdir -p "$CERTS"; cp "$CA" "$CERTS/ca.crt"
podman login --cert-dir "$CERTS" --authfile "$TOKENS/consumer-podman.json" -u consumer --password-stdin \
  "localhost:${HTTPS_PORT}" < "$TOKENS/consumer.token" >/dev/null && log "podman auth (consumer): $TOKENS/consumer-podman.json"
podman login --cert-dir "$CERTS" --authfile "$TOKENS/ci-podman.json" -u ci --password-stdin \
  "localhost:${HTTPS_PORT}" < "$TOKENS/ci-oci.token" >/dev/null && log "podman auth (ci, oci-apps): $TOKENS/ci-podman.json"

# --- trust repo: the CA certificate -------------------------------------------
want=$(sha256sum "$CA" | cut -d' ' -f1)
have=$(akcurl -sS "$U/api/v1/repositories/trust/download/ak-internal-ca.crt" | sha256sum | cut -d' ' -f1)
if [[ "$have" == "$want" ]]; then log "trust/ak-internal-ca.crt up to date"; else
  api DELETE /repositories/trust/artifacts/ak-internal-ca.crt -o /dev/null >/dev/null || true
  r=$(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $JWT" -H 'Content-Type: application/x-pem-file' \
        -X PUT --data-binary "@$CA" "$U/api/v1/repositories/trust/artifacts/ak-internal-ca.crt")
  [[ "$r" =~ ^20 ]] || { echo "bootstrap.sh: CA upload failed: HTTP $r" >&2; exit 1; }
  log "uploaded trust/ak-internal-ca.crt"
fi
log "done. Tokens in $TOKENS (never commit). CA: $CA"
