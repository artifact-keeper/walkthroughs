#!/usr/bin/env bash
# Idempotently configure the ak-offgrid registry: every repository the AI stack is served
# from, the offline settings on every Remote (set before anything is cached), the egress
# ledger as every Remote's egress proxy, users and tokens.
#
# Remote repositories (all private or internal; each one is frozen at creation and sends its
# upstream traffic through the egress ledger, http://egress-ledger:3128):
#   oci-dockerhub  docker        https://registry-1.docker.io   base images (python, node)
#   oci-ghcr       docker        https://ghcr.io                the llama.cpp server image, the trivy DB
#   pypi-remote    pypi          https://pypi.org               openai, mcp, huggingface_hub, the public MCP server
#   npm-remote     npm           https://registry.npmjs.org     pi (step 6)
#   hf-hub         huggingface   https://huggingface.co         the model, pinned to a commit
#   mcp-official   mcp           https://registry.modelcontextprotocol.io   approval required
#   plugins        agentplugins  http://ak-central:8080/agentplugins/plugins-central
#                                (this instance's own hosted marketplace, standing in for a
#                                central Artifact Keeper; #5334)
# Hosted and Virtual repositories:
#   pypi-local     pypi, Local       Acme's internal MCP server package
#   pypi           pypi, Virtual     pypi-local, then pypi-remote (what pip uses)
#   hf-models      huggingface, Local  the vetted model: scanned on upload, block_unscanned
#   mcp-internal   mcp, Local        Acme's internal MCP server entry (own-repos, com.acme)
#   mcp-all        mcp, Virtual      mcp-internal, then mcp-official (what the agent reads)
#   plugins-central agentplugins, Local  the "central" marketplace the plugins Remote proxies
#
# Offline settings on every Remote, before the first fetch (docs/air-gapped.md, section 3):
# cache-ttl 315360000 s, on-upstream-not-found keep, stale-if-error grace 2592000 s. A raised
# cache-ttl applies to an entry only from its next revalidation, so it is set at creation.
#
# Users and tokens (in registry/.tokens/, gitignored, mode 600):
#   admin.token      admin API token for the scripts (30 days)
#   developer.token  user developer: read on every repository (what the agent, pip, hf and
#                    podman on the site use). Scope read:artifacts
#   publisher.token  user publisher: write on the hosted repositories (the model, the internal
#                    package, the MCP entry, the plugin). Scopes read:artifacts, write:artifacts
#   site-sync.token  user site-sync: read on plugins-central only; the plugins Remote's
#                    upstream credential
# plus a podman auth file developer-podman.json for image pulls from the host.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
command -v jq >/dev/null || { echo "bootstrap.sh: jq is required" >&2; exit 1; }
U="$(AK_HOST_URL)"
log() { echo "bootstrap: $*"; }
mkdir -p "$TOKENS" "$OUT"; chmod 700 "$TOKENS"
[[ $(phase) == seed ]] || { echo "bootstrap.sh: the stack is on the site network; bootstrap runs while seeding" >&2; exit 1; }

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
die() { echo "bootstrap.sh: $*" >&2; exit 1; }

# --- repositories -------------------------------------------------------------
create_repo() { # key json
  local key=$1 body=$2 r
  r=$(api GET "/repositories/$key")
  if [[ $(code_of "$r") == 200 ]]; then log "repo $key exists"; return; fi
  r=$(api POST /repositories -d "$body")
  [[ $(code_of "$r") =~ ^20 ]] || die "creating $key failed: HTTP $(code_of "$r") $(body_of "$r")"
  log "repo $key created: $(body_of "$r" | jq -c '{format,repo_type,visibility,upstream_url}')"
}
# Every Remote is created with its egress proxy in the create body (#5402, #5406): the
# repository's first upstream request already goes through the ledger.
remote() { # key format upstream visibility [extra-json]
  create_repo "$1" "$(jq -nc --arg k "$1" --arg f "$2" --arg u "$3" --arg v "$4" --argjson x "${5:-{\}}" \
    '{key:$k,name:($k+" (Remote of "+$u+")"),format:$f,repo_type:"remote",upstream_url:$u,visibility:$v,
      egress_proxy:{mode:"explicit",proxy_url:"http://egress-ledger:3128"}} + $x')"
}
remote oci-dockerhub docker https://registry-1.docker.io internal
remote oci-ghcr      docker https://ghcr.io internal
remote pypi-remote   pypi   https://pypi.org internal
remote npm-remote    npm    https://registry.npmjs.org internal
remote hf-hub        huggingface https://huggingface.co private
# mcp-official never runs a scheduled sync (mcp_remote_sync_paused, set at create): the site
# needs two named servers, not the 220,000 entries of the public registry. seed/seed.sh seeds
# exactly the versions the manifest lists (POST .../mcp/seed, #5408).
remote mcp-official  mcp    https://registry.modelcontextprotocol.io private \
  '{"mcp_package_repos":{"pypi":"pypi-remote"},"mcp_remote_sync_paused":true}'

create_repo pypi-local '{"key":"pypi-local","name":"Acme internal Python packages","format":"pypi","repo_type":"local","visibility":"internal"}'
create_repo pypi '{"key":"pypi","name":"pypi: Acme first, then pypi.org","format":"pypi","repo_type":"virtual","visibility":"internal",
  "member_repos":[{"repo_key":"pypi-local","priority":1},{"repo_key":"pypi-remote","priority":2}]}'
create_repo hf-models '{"key":"hf-models","name":"Vetted models","format":"huggingface","repo_type":"local","visibility":"private"}'
create_repo mcp-internal '{"key":"mcp-internal","name":"Acme internal MCP servers","format":"mcp","repo_type":"local","visibility":"private",
  "mcp_package_policy":"own-repos","mcp_package_repos":{"pypi":"pypi-local"},"mcp_namespace_allow":["com.acme"]}'
create_repo mcp-all '{"key":"mcp-all","name":"MCP servers: Acme first, then the approved public ones","format":"mcp","repo_type":"virtual","visibility":"private",
  "member_repos":[{"repo_key":"mcp-internal","priority":1},{"repo_key":"mcp-official","priority":2}]}'
create_repo plugins-central '{"key":"plugins-central","name":"Central plugin marketplace (stands in for the central instance)","format":"agentplugins","repo_type":"local","visibility":"private"}'
# The plugins Remote is created below, once site-sync's token exists for its upstream auth.

rid() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }

# hf-models: every uploaded model file is scanned (the model-file scanner reads GGUF headers,
# safetensors headers and pickles, #5337), and a file no scan has completed is not served.
r=$(api PUT /repositories/hf-models/security -d '{"scan_enabled":true,"scan_on_upload":true}')
[[ $(code_of "$r") == 200 ]] || die "hf-models security: $(body_of "$r")"
pol=$(body_of "$(api GET /security/policies)" | jq -r '(if type=="array" then . else .items end)[] | select(.name=="hf-models-vetted") | .id' | head -1)
if [[ -n "$pol" ]]; then log "policy hf-models-vetted exists"; else
  r=$(api POST /security/policies -d "$(jq -nc --arg r "$(rid hf-models)" '{name:"hf-models-vetted",
      repository_id:$r,max_severity:"medium",block_unscanned:true,block_on_fail:true}')")
  [[ $(code_of "$r") =~ ^20 ]] || die "policy hf-models-vetted: $(body_of "$r")"
  log "policy hf-models-vetted: $(body_of "$r" | jq -c '{max_severity,block_unscanned,block_on_fail}')"
fi

# --- users, permissions, tokens ----------------------------------------------
works() { # token-file -> 0 if the token authenticates
  [[ -s "$1" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$1")" \
       "$U/api/v1/auth/me") == 200 ]]
}
user_id() { body_of "$(api GET "/users?per_page=200")" | jq -r --arg n "$1" '(if type=="array" then . else .items end)[] | select(.username==$n) | .id'; }
grant() { # user-id repo actions-json
  local uid=$1 repo=$2 actions=$3 r have target
  target=$(rid "$repo")
  have=$(body_of "$(api GET "/permissions?per_page=500")" | jq -r --arg u "$uid" --arg r "$target" \
    '(if type=="array" then . else .items end)[] | select(.principal_id==$u and .target_id==$r) | .id' | head -1)
  [[ -z "$have" ]] || return 0
  r=$(api POST /permissions -d "$(jq -nc --arg u "$uid" --arg r "$target" --argjson a "$actions" \
      '{principal_type:"user",principal_id:$u,target_type:"repository",target_id:$r,actions:$a}')")
  [[ $(code_of "$r") =~ ^20 ]] || die "permission on $repo failed: HTTP $(code_of "$r") $(body_of "$r")"
  log "  granted $actions on $repo"
}
ensure_user() { # name display scopes-json
  local name=$1 display=$2 scopes=$3 pwf="$TOKENS/$1.password" uid r ujwt
  uid=$(user_id "$name")
  if [[ -z "$uid" ]]; then
    (umask 077; echo "Uk$(openssl rand -hex 16)" > "$pwf")
    r=$(api POST /users -d "$(jq -nc --arg n "$name" --arg d "$display" --arg p "$(cat "$pwf")" \
        '{username:$n,email:($n+"@acme.example"),password:$p,display_name:$d,is_admin:false}')")
    [[ $(code_of "$r") =~ ^20 ]] || die "create user $name failed: HTTP $(code_of "$r") $(body_of "$r")"
    uid=$(body_of "$r" | jq -r '.user.id // .id')
    log "created user $name ($uid)"
  fi
  USER_ID=$uid
  if works "$TOKENS/$name.token"; then log "$name.token still valid"; return; fi
  ujwt=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg n "$name" --arg p "$(cat "$pwf")" '{username:$n,password:$p}')" | jq -r .access_token)
  [[ -n "$ujwt" && "$ujwt" != null ]] || die "$name login failed"
  (umask 077; akcurl -fsS -X POST "$U/api/v1/auth/tokens" -H "Authorization: Bearer $ujwt" -H 'Content-Type: application/json' \
     -d "$(jq -nc --arg n "$name-walkthrough" --argjson s "$scopes" '{name:$n,scopes:$s,expires_in_days:30}')" \
     | jq -r .token > "$TOKENS/$name.token")
  log "minted $name.token (user $name, scopes $scopes, 30 days)"
}

ensure_user site-sync "The site's plugins Remote (reads the central marketplace)" '["read:artifacts"]'
grant "$USER_ID" plugins-central '["read"]'

# The plugins Remote: the upstream is this instance's hosted marketplace, by the backend's
# alias ak-central on the compose network (http, no TLS: the backend's own port; the name
# `backend` is on the upstream hostname blocklist). The SSRF guard admits the
# backend's fixed address only (compose.override.yml). The credential is site-sync's token.
remote plugins agentplugins http://ak-central:8080/agentplugins/plugins-central private
r=$(api PUT /repositories/plugins/upstream-auth -d "$(jq -nc --rawfile t "$TOKENS/site-sync.token" '{auth_type:"bearer",password:($t|rtrimstr("\n"))}')")
[[ $(code_of "$r") =~ ^20 ]] || die "plugins upstream-auth: HTTP $(code_of "$r") $(body_of "$r")"
log "repo plugins: upstream auth bearer (site-sync)"

REMOTES=(oci-dockerhub oci-ghcr pypi-remote npm-remote hf-hub mcp-official plugins)
for r in "${REMOTES[@]}"; do
  r1=$(api PUT "/repositories/$r/cache-ttl" -d '{"cache_ttl_seconds":315360000}')
  r2=$(api PUT "/repositories/$r/on-upstream-not-found" -d '{"on_upstream_not_found":"keep"}')
  r3=$(api PUT "/repositories/$r/stale-if-error-grace" -d '{"stale_if_error_grace_seconds":2592000}')
  r4=$(api GET "/repositories/$r/egress-proxy")   # set at create; read back
  for x in "$r1" "$r2" "$r3" "$r4"; do
    [[ $(code_of "$x") == 200 ]] || die "offline settings on $r failed: HTTP $(code_of "$x") $(body_of "$x")"
  done
  log "repo $r: cache-ttl 315360000, on-upstream-not-found keep, stale grace 2592000, egress-proxy $(body_of "$r4" | jq -c '{mode,proxy_url}')"
done

ensure_user developer "A developer on the site (read only)" '["read:artifacts"]'
for r in "${REMOTES[@]}" pypi-local pypi hf-models mcp-internal mcp-all plugins-central; do grant "$USER_ID" "$r" '["read"]'; done
ensure_user publisher "Acme platform team (publishes vetted content)" '["read:artifacts","write:artifacts"]'
for r in pypi-local hf-models mcp-internal plugins-central; do grant "$USER_ID" "$r" '["read","write"]'; done
for r in pypi hf-hub; do grant "$USER_ID" "$r" '["read"]'; done

# --- podman on the host: image pulls through the registry --------------------------
# The host cannot resolve ak.internal; it uses the loopback port by the name localhost,
# for which Caddy issues a certificate from the same internal CA.
CERTS="$OUT/certs.d/localhost:${HTTPS_PORT}"
mkdir -p "$CERTS"; cp "$CA" "$CERTS/ca.crt"
podman login --cert-dir "$CERTS" --authfile "$TOKENS/developer-podman.json" -u developer --password-stdin \
  "localhost:${HTTPS_PORT}" < "$TOKENS/developer.token" >/dev/null || die "podman login failed"
log "podman auth (developer): $TOKENS/developer-podman.json"

log "done. Tokens in $TOKENS (never commit). CA: $CA"
