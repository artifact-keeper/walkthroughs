#!/usr/bin/env bash
# Idempotently configure the ak-agent registry for the walkthrough:
#   - repositories (see README.md for the table):
#       PyPI:  pypi-internal (hosted), pypi-remote (pypi.org), pypi-virtual (internal p1,
#              remote p2): the only index the agent knows
#       npm:   npm-internal (hosted), npm-remote (registry.npmjs.org), npm-virtual (same
#              order, hosted names isolated): the only registry the agent knows
#       Lab:   pypi-lab / npm-lab (remotes on the lab upstream) behind pypi-lab-virtual /
#              npm-lab-virtual (internal p1, lab p2), for the deterministic cooldown and
#              name-squat tests. They are separate virtuals because in 1.11.7 a virtual with
#              two age-gated remotes refuses a package only the second one serves (F10).
#       OCI:   oci-dockerhub, oci-ghcr (base images for the agent sandbox)
#       trust: generic, public: the internal CA certificate
#   - upstream filter on npm-remote: nothing under @acme/ is ever fetched from npmjs.org
#   - visibility "internal" (any signed-in user may read; every token below narrows that
#     with a repo selector or is pinned to one repository)
#   - tokens (in registry/.tokens/, gitignored, mode 600):
#       agent.token      user "agent": read:artifacts on the four virtuals only
#       ci-pypi.token    repo token on pypi-internal, read+write (publishing)
#       ci-npm.token     repo token on npm-internal, read+write (publishing)
#       builder.token    user "builder": read:artifacts on oci-dockerhub and oci-ghcr
#     plus a podman auth file builder-podman.json for base-image pulls from the host
#   - uploads the internal CA to trust/ak-internal-ca.crt
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
command -v jq >/dev/null || { echo "bootstrap.sh: jq is required" >&2; exit 1; }
U="$(AK_HOST_URL)"
LAB_URL="${LAB_URL:-http://172.31.50.200:8080}"
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
  JWT=$(<"$TOKENS/admin.token")
  log "minted admin.token (scopes *, 30 days) for the other scripts"
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
  log "repo $key created: $(body_of "$r" | jq -c '{format,repo_type,upstream_url}')"
}
create_repo pypi-internal '{"key":"pypi-internal","name":"Internal Python packages","format":"pypi","repo_type":"local","visibility":"internal"}'
create_repo pypi-remote '{"key":"pypi-remote","name":"PyPI (proxy)","format":"pypi","repo_type":"remote","visibility":"internal","upstream_url":"https://pypi.org"}'
create_repo pypi-lab "$(jq -nc --arg u "$LAB_URL" '{key:"pypi-lab",name:"Lab upstream (stand-in for a second public index)",format:"pypi",repo_type:"remote",visibility:"internal",upstream_url:$u}')"
create_repo pypi-virtual '{"key":"pypi-virtual","name":"Python: internal first, then PyPI","format":"pypi","repo_type":"virtual","visibility":"internal",
  "member_repos":[{"repo_key":"pypi-internal","priority":1},{"repo_key":"pypi-remote","priority":2}]}'
create_repo pypi-lab-virtual '{"key":"pypi-lab-virtual","name":"Python: internal first, then the lab upstream","format":"pypi","repo_type":"virtual","visibility":"internal",
  "member_repos":[{"repo_key":"pypi-internal","priority":1},{"repo_key":"pypi-lab","priority":2}]}'
create_repo npm-internal '{"key":"npm-internal","name":"Internal npm packages (@acme)","format":"npm","repo_type":"local","visibility":"internal"}'
create_repo npm-remote '{"key":"npm-remote","name":"npm (proxy)","format":"npm","repo_type":"remote","visibility":"internal","upstream_url":"https://registry.npmjs.org"}'
create_repo npm-lab "$(jq -nc --arg u "$LAB_URL" '{key:"npm-lab",name:"Lab upstream (stand-in for a second public registry)",format:"npm",repo_type:"remote",visibility:"internal",upstream_url:$u}')"
create_repo npm-virtual '{"key":"npm-virtual","name":"npm: internal first, then npmjs","format":"npm","repo_type":"virtual","visibility":"internal",
  "npm_virtual_isolate_hosted_names":true,
  "member_repos":[{"repo_key":"npm-internal","priority":1},{"repo_key":"npm-remote","priority":2}]}'
create_repo npm-lab-virtual '{"key":"npm-lab-virtual","name":"npm: internal first, then the lab upstream","format":"npm","repo_type":"virtual","visibility":"internal",
  "npm_virtual_isolate_hosted_names":true,
  "member_repos":[{"repo_key":"npm-internal","priority":1},{"repo_key":"npm-lab","priority":2}]}'
create_repo oci-dockerhub '{"key":"oci-dockerhub","name":"Docker Hub (proxy)","format":"docker","repo_type":"remote","visibility":"internal","upstream_url":"https://registry-1.docker.io"}'
create_repo oci-ghcr '{"key":"oci-ghcr","name":"ghcr.io (proxy)","format":"docker","repo_type":"remote","visibility":"internal","upstream_url":"https://ghcr.io"}'
create_repo trust '{"key":"trust","name":"Trust anchors: the internal CA certificate","format":"generic","repo_type":"local","visibility":"public"}'

# npm-remote never fetches @acme/* from npmjs.org (there is no scope deny-list; the
# upstream filter refuses the path with 404 before contacting the upstream).
r=$(api PUT /repositories/npm-remote/upstream-filter -d '{"exclude_patterns":["^/?@acme(/|%2[Ff])"]}')
must "upstream filter on npm-remote" "$r"; log "npm-remote upstream filter: $(body_of "$r" | jq -c . 2>/dev/null || true)"

# --- users and tokens ---------------------------------------------------------
works() { # token path -> 0 if GET path is 200 with the token
  [[ -s "$1" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$1")" "$U$2") == 200 ]]
}
repo_id() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }
mint_repo_token() { # repo name scopes-json out
  local r
  r=$(api POST "/repositories/$1/tokens" -d "$(jq -nc --arg n "$2" --argjson s "$3" '{name:$n,scopes:$s,expires_in_days:90}')")
  must "repo token on $1" "$r"
  (umask 077; body_of "$r" | jq -r .token > "$4")
}
ensure_user() { # username display-name -> password file
  local u=$1 pwf="$TOKENS/$1.password" r uid
  r=$(api GET "/users?per_page=200")
  uid=$(body_of "$r" | jq -r --arg u "$u" '(if type=="array" then . else .items end)[] | select(.username==$u) | .id' 2>/dev/null || true)
  if [[ -z "$uid" ]]; then
    (umask 077; echo "Ag$(openssl rand -hex 16)" > "$pwf")
    r=$(api POST /users -d "$(jq -nc --arg u "$u" --arg p "$(cat "$pwf")" --arg d "$2" \
        '{username:$u,email:($u+"@ak.internal"),password:$p,display_name:$d,is_admin:false}')")
    must "create user $u" "$r"; log "created user $u"
  fi
}
user_token() { # username token-name out repo-keys...
  local u=$1 name=$2 out=$3 ids ujwt r; shift 3
  ids=$(for k in "$@"; do repo_id "$k"; done | jq -R . | jq -sc .)
  # Minted by the user itself (POST /auth/tokens accepts repo_selector).
  ujwt=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg u "$u" --arg p "$(cat "$TOKENS/$u.password")" '{username:$u,password:$p}')" | jq -r .access_token)
  r=$(akcurl -sS -X POST "$U/api/v1/auth/tokens" -H "Authorization: Bearer $ujwt" -H 'Content-Type: application/json' \
      -w '\n%{http_code}' -d "$(jq -nc --arg n "$name" --argjson ids "$ids" \
      '{name:$n,scopes:["read:artifacts"],expires_in_days:90,repo_selector:{match_repos:$ids}}')")
  must "token for $u" "$r"
  (umask 077; body_of "$r" | jq -r .token > "$out")
}

ensure_user agent "AI coding agent (read only, two virtual repositories)"
if works "$TOKENS/agent.token" /api/v1/auth/me; then log "agent.token still valid"; else
  user_token agent agent-read "$TOKENS/agent.token" pypi-virtual npm-virtual pypi-lab-virtual npm-lab-virtual
  log "minted agent.token (user agent, read:artifacts, selector: the four virtuals)"
fi
ensure_user builder "Image builder (read only, base-image proxies)"
if works "$TOKENS/builder.token" /api/v1/auth/me; then log "builder.token still valid"; else
  user_token builder builder-read "$TOKENS/builder.token" oci-dockerhub oci-ghcr
  log "minted builder.token (user builder, read:artifacts, selector: oci-dockerhub oci-ghcr)"
fi
if works "$TOKENS/ci-pypi.token" /api/v1/auth/me; then log "ci-pypi.token still valid"; else
  mint_repo_token pypi-internal ci-publish '["read:artifacts","write:artifacts"]' "$TOKENS/ci-pypi.token"
  log "minted ci-pypi.token (repo token on pypi-internal: read+write, 90 days)"
fi
if works "$TOKENS/ci-npm.token" /api/v1/auth/me; then log "ci-npm.token still valid"; else
  mint_repo_token npm-internal ci-publish '["read:artifacts","write:artifacts"]' "$TOKENS/ci-npm.token"
  log "minted ci-npm.token (repo token on npm-internal: read+write, 90 days)"
fi

# --- podman on the host: base-image pulls through the registry ----------------
# The host cannot resolve ak.internal; it uses the loopback port by the name localhost,
# for which Caddy issues a DNS:localhost certificate from the same internal CA.
CERTS="$OUT/certs.d/localhost:${HTTPS_PORT}"
mkdir -p "$CERTS"; cp "$CA" "$CERTS/ca.crt"
podman login --cert-dir "$CERTS" --authfile "$TOKENS/builder-podman.json" -u builder --password-stdin \
  "localhost:${HTTPS_PORT}" < "$TOKENS/builder.token" >/dev/null && log "podman auth (builder): $TOKENS/builder-podman.json"

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
