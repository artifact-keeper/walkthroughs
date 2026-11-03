#!/usr/bin/env bash
# Idempotently configure the ak-gate registry for the walkthrough:
#   - five Remote repositories, one per package manager, visibility public (the clients
#     read them anonymously; tokens for clients are shown in the other walkthroughs):
#       go-proxy      go      https://proxy.golang.org
#       cargo-proxy   cargo   https://index.crates.io   (sparse index; crates from static.crates.io)
#       npm-proxy     npm     https://registry.npmjs.org
#       debian-proxy  debian  https://deb.debian.org/debian
#       alpine-proxy  alpine  https://dl-cdn.alpinelinux.org/alpine
#   - npm-internal (hosted, internal): where a vendored package goes in the exception
#     step, with a scan policy (max_severity high, block unscanned, block on failed scan)
#   - tokens (in registry/.tokens/, gitignored, mode 600):
#       admin.token     API token with every scope, for the scripts
#       ci-npm.token    repo token on npm-internal, read+write (npm publish)
# Scan-on-proxy itself is configured by policy/mode.sh, not here.
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
     -d '{"name":"walkthrough-admin","scopes":["*"],"expires_in_days":90}' | jq -r .token > "$TOKENS/admin.token")
  JWT=$(<"$TOKENS/admin.token")
  log "minted admin.token (scopes *, 90 days) for the other scripts"
fi

api() { # api METHOD PATH [curl args...]  -> body, then HTTP code on the last line
  local m=$1 p=$2; shift 2
  akcurl -sS -X "$m" "$U/api/v1$p" -H "Authorization: Bearer $JWT" \
       -H 'Content-Type: application/json' -w '\n%{http_code}' "$@"
}
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
must() { # must "what" response
  [[ $(code_of "$2") =~ ^20 ]] || { echo "bootstrap.sh: $1 failed: HTTP $(code_of "$2") $(body_of "$2")" >&2; exit 1; }
}

# --- repositories -------------------------------------------------------------
create_repo() { # key json
  local key=$1 body=$2 r
  r=$(api GET "/repositories/$key")
  if [[ $(code_of "$r") == 200 ]]; then log "repo $key exists"; return; fi
  r=$(api POST /repositories -d "$body"); must "creating $key" "$r"
  log "repo $key created: $(body_of "$r" | jq -c '{format,repo_type,visibility,upstream_url}')"
}
create_repo go-proxy     '{"key":"go-proxy","name":"Go modules (proxy.golang.org)","format":"go","repo_type":"remote","visibility":"public","upstream_url":"https://proxy.golang.org"}'
create_repo cargo-proxy  '{"key":"cargo-proxy","name":"Rust crates (crates.io)","format":"cargo","repo_type":"remote","visibility":"public","upstream_url":"https://index.crates.io"}'
create_repo npm-proxy    '{"key":"npm-proxy","name":"npm (registry.npmjs.org)","format":"npm","repo_type":"remote","visibility":"public","upstream_url":"https://registry.npmjs.org"}'
create_repo debian-proxy '{"key":"debian-proxy","name":"Debian (deb.debian.org)","format":"debian","repo_type":"remote","visibility":"public","upstream_url":"https://deb.debian.org/debian"}'
create_repo alpine-proxy '{"key":"alpine-proxy","name":"Alpine (dl-cdn.alpinelinux.org)","format":"alpine","repo_type":"remote","visibility":"public","upstream_url":"https://dl-cdn.alpinelinux.org/alpine"}'
create_repo npm-internal '{"key":"npm-internal","name":"Internal npm packages (vendored, reviewed)","format":"npm","repo_type":"local","visibility":"internal"}'

# --- scan every upload to npm-internal, and a scan policy on it ----------------
r=$(api PUT /repositories/npm-internal/security -d '{"scan_enabled":true,"scan_on_upload":true}')
must "scan-on-upload npm-internal" "$r"; log "npm-internal: scan_on_upload $(body_of "$r" | jq -c '{scan_enabled,scan_on_upload}')"
sid=$(body_of "$(api GET /repositories/npm-internal)" | jq -r .id)
pol=$(body_of "$(api GET /security/policies)" | jq -r '(if type=="array" then . else .items end)[] | select(.name=="npm-internal-gate") | .id' | head -1 2>/dev/null || true)
if [[ -n "$pol" ]]; then log "policy npm-internal-gate exists ($pol)"; else
  r=$(api POST /security/policies -d "$(jq -nc --arg rid "$sid" \
       '{name:"npm-internal-gate",repository_id:$rid,max_severity:"high",block_unscanned:true,block_on_fail:true,require_signature:false}')")
  must "creating policy npm-internal-gate" "$r"
  log "policy npm-internal-gate created on npm-internal: $(body_of "$r" | jq -c '{max_severity,block_unscanned,block_on_fail}')"
fi

# --- tokens -------------------------------------------------------------------
works() { [[ -s "$1" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$1")" "$U$2") == 200 ]]; }
if works "$TOKENS/ci-npm.token" /api/v1/auth/me; then log "ci-npm.token still valid"; else
  r=$(api POST /repositories/npm-internal/tokens -d '{"name":"ci-publish","scopes":["read:artifacts","write:artifacts"],"expires_in_days":90}')
  must "repo token on npm-internal" "$r"
  (umask 077; body_of "$r" | jq -r .token > "$TOKENS/ci-npm.token")
  log "minted ci-npm.token (repo token on npm-internal: read+write, 90 days)"
fi

# Note: the Debian and Alpine Remotes pass the upstream InRelease and APKINDEX.tar.gz through
# with the upstream signatures intact (gpg-key.asc and <branch>/keys/ answer 404 "No signing
# key configured" for a Remote), so apt and apk verify them with the keys their images ship.
log "done. Tokens in $TOKENS (never commit). CA: $CA"
