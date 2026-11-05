#!/usr/bin/env bash
# Idempotently configure the ak-mcp registry for the walkthrough.
#
# Repositories (all private):
#   npm-internal   npm, Local     internal npm packages (the MCP servers' code)
#   npm-remote     npm, Remote    https://registry.npmjs.org (dependencies, upstream servers)
#   npm            npm, Virtual   npm-internal + npm-remote: the one npm URL clients use
#   oci-internal   docker, Local  internal MCP server images
#   mcp-internal   mcp, Local     the private registry: own-repos package policy, packages
#                                 in npm-internal / oci-internal, namespace com.acme only
#   mcp-upstream   mcp, Remote    the curated proxy (step 3); created by flows/curate.sh
#   mcp            mcp, Virtual   mcp-internal + mcp-upstream; created by flows/virtual.sh
#
# Users and tokens (in registry/.tokens/, gitignored, mode 600):
#   admin.token      admin API token for the scripts (30 days)
#   ci.token         user ci: write on mcp-internal, npm-internal, oci-internal; read on the
#                    rest. Scopes read:artifacts, write:artifacts (what a pipeline publishes with)
#   developer.token  user developer: read on every repository. Scopes read:artifacts,
#                    read:repositories (installs, and asking for an approval)
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
  log "repo $key created: $(body_of "$r" | jq -c '{format,repo_type,visibility}')"
}
create_repo npm-internal '{"key":"npm-internal","name":"Internal npm packages","format":"npm",
  "repo_type":"local","visibility":"private"}'
create_repo npm-remote '{"key":"npm-remote","name":"npmjs.org through Artifact Keeper","format":"npm",
  "repo_type":"remote","upstream_url":"https://registry.npmjs.org","visibility":"private"}'
create_repo npm '{"key":"npm","name":"npm: internal first, then npmjs.org","format":"npm",
  "repo_type":"virtual","visibility":"private"}'
r=$(api PUT /repositories/npm/members -d '{"members":[{"member_key":"npm-internal","priority":1},{"member_key":"npm-remote","priority":2}]}')
[[ $(code_of "$r") =~ ^20 ]] || die "npm members failed: HTTP $(code_of "$r") $(body_of "$r")"
log "npm virtual members: npm-internal, npm-remote"
create_repo oci-internal '{"key":"oci-internal","name":"Internal MCP server images","format":"docker",
  "repo_type":"local","visibility":"private"}'

# The private MCP registry. own-repos is the default package policy; it is spelled out here.
create_repo mcp-internal '{"key":"mcp-internal","name":"Acme internal MCP servers",
  "description":"MCP servers built and published by Acme teams",
  "format":"mcp","repo_type":"local","visibility":"private",
  "mcp_package_policy":"own-repos",
  "mcp_package_repos":{"npm":"npm-internal","oci":"oci-internal"},
  "mcp_namespace_allow":["com.acme"]}'
log "mcp-internal settings: $(body_of "$(api GET /repositories/mcp-internal)" | jq -c '{mcp_package_policy,mcp_package_repos,mcp_namespace_allow}')"

# A scan policy on mcp-internal at max_severity high: a lint finding of action `review`
# (severity high) holds the version until someone acknowledges it (step 4).
rid() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }
MCP_ID=$(rid mcp-internal)
pol=$(body_of "$(api GET /security/policies)" | jq -r '(if type=="array" then . else .items end)[] | select(.name=="mcp-internal-review") | .id' | head -1)
if [[ -n "$pol" ]]; then log "policy mcp-internal-review exists ($pol)"; else
  r=$(api POST /security/policies -d "$(jq -nc --arg rid "$MCP_ID" '{name:"mcp-internal-review",repository_id:$rid,
        max_severity:"high",block_unscanned:false,block_on_fail:true}')")
  [[ $(code_of "$r") =~ ^20 ]] || die "policy failed: HTTP $(code_of "$r") $(body_of "$r")"
  log "policy mcp-internal-review on mcp-internal: $(body_of "$r" | jq -c '{max_severity,block_unscanned,block_on_fail}')"
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

ensure_user ci "CI publisher" '["read:artifacts","write:artifacts"]'
for r in mcp-internal npm-internal oci-internal; do grant "$USER_ID" "$r" '["read","write"]'; done
for r in npm npm-remote; do grant "$USER_ID" "$r" '["read"]'; done

ensure_user developer "A developer (read only)" '["read:artifacts","read:repositories"]'
for r in mcp-internal npm npm-internal npm-remote oci-internal; do grant "$USER_ID" "$r" '["read"]'; done

log "done. Tokens in $TOKENS (never commit). CA: $CA"
