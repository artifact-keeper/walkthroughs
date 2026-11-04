#!/usr/bin/env bash
# Idempotently configure the ak-agents registry for the walkthrough:
#   - repositories: agent-plugins (agentplugins, hosted, private; scan on upload, the
#     agent-plugins-release scan policy), agent-plugins-public (agentplugins, hosted,
#     public), trust (generic, public: the internal CA certificate)
#   - two users: ci (read and write on agent-plugins) and developer (read on agent-plugins)
#   - tokens (in registry/.tokens/, gitignored, mode 600):
#       admin.token      admin API token for the scripts (30 days)
#       ci.token         repository token on agent-plugins, read+write, minted by the ci user
#                        itself, so every publish is recorded as ci's (what CI publishes with)
#       developer.token  repository token on agent-plugins, read only, minted by the
#                        developer user itself (what workstations read with)
#       public-ci.token  repository token on agent-plugins-public, read+write; it also
#                        shows that a token for one repository cannot read another
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
create_repo agent-plugins '{"key":"agent-plugins","name":"Internal agent plugins",
  "description":"Plugins for AI coding agents, published by the platform team",
  "format":"agentplugins","repo_type":"local","visibility":"private"}'
create_repo agent-plugins-public '{"key":"agent-plugins-public","name":"Public agent plugins",
  "description":"Agent plugins anyone may install, no credentials needed",
  "format":"agentplugins","repo_type":"local","visibility":"public"}'
create_repo trust '{"key":"trust","name":"Trust anchors: the internal CA certificate",
  "format":"generic","repo_type":"local","visibility":"public"}'
repo_id() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }

# --- scanning: every upload to agent-plugins is scanned, and nothing unscanned is served
r=$(api PUT /repositories/agent-plugins/security -d '{"scan_enabled":true,"scan_on_upload":true}')
[[ $(code_of "$r") =~ ^20 ]] || die "scan settings failed: HTTP $(code_of "$r") $(body_of "$r")"
log "agent-plugins: scan_enabled, scan_on_upload"
rid=$(repo_id agent-plugins)
pol=$(body_of "$(api GET /security/policies)" | jq -r '(if type=="array" then . else .items end)[] | select(.name=="agent-plugins-release") | .id' | head -1)
if [[ -n "$pol" ]]; then log "policy agent-plugins-release exists ($pol)"; else
  r=$(api POST /security/policies -d "$(jq -nc --arg rid "$rid" '{name:"agent-plugins-release",repository_id:$rid,
        max_severity:"high",block_unscanned:true,block_on_fail:true}')")
  [[ $(code_of "$r") =~ ^20 ]] || die "policy failed: HTTP $(code_of "$r") $(body_of "$r")"
  log "policy agent-plugins-release on agent-plugins: $(body_of "$r" | jq -c '{max_severity,block_unscanned,block_on_fail}')"
fi

# --- tokens -------------------------------------------------------------------
works() { # token-file repo -> 0 if the token reads that repository's marketplace
  [[ -s "$1" ]] && [[ $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$1")" \
       "$U/agentplugins/$2/marketplace.json") == 200 ]]
}
mint_repo_token() { # bearer repo name scopes-json out
  local r
  r=$(akcurl -sS -X POST "$U/api/v1/repositories/$2/tokens" -H "Authorization: Bearer $1" \
        -H 'Content-Type: application/json' -w '\n%{http_code}' \
        -d "$(jq -nc --arg n "$3" --argjson s "$4" '{name:$n,scopes:$s,expires_in_days:30}')")
  [[ $(code_of "$r") =~ ^20 ]] || die "repo token $3 on $2 failed: HTTP $(code_of "$r") $(body_of "$r")"
  (umask 077; body_of "$r" | jq -r .token > "$5")
}

if works "$TOKENS/public-ci.token" agent-plugins-public; then log "public-ci.token still valid"; else
  mint_repo_token "$JWT" agent-plugins-public public-ci-publish '["read:artifacts","write:artifacts"]' "$TOKENS/public-ci.token"
  log "minted public-ci.token (repository token on agent-plugins-public: read+write, 30 days)"
fi

# Users for CI and for a developer: non-admin, with a permission on agent-plugins, each holding
# a token for that one repository that it minted itself (a non-admin can only mint what it
# holds, and the registry records the minting user as the actor of every request).
ensure_user() { # name display actions-json token-name scopes-json
  local name=$1 display=$2 actions=$3 tname=$4 scopes=$5 pwf="$TOKENS/$1.password" uid have r ujwt
  uid=$(body_of "$(api GET "/users?per_page=200")" | jq -r --arg n "$name" '(if type=="array" then . else .items end)[] | select(.username==$n) | .id')
  if [[ -z "$uid" ]]; then
    (umask 077; echo "Uk$(openssl rand -hex 16)" > "$pwf")
    r=$(api POST /users -d "$(jq -nc --arg n "$name" --arg d "$display" --arg p "$(cat "$pwf")" \
        '{username:$n,email:($n+"@ak.internal"),password:$p,display_name:$d,is_admin:false}')")
    [[ $(code_of "$r") =~ ^20 ]] || die "create user $name failed: HTTP $(code_of "$r") $(body_of "$r")"
    uid=$(body_of "$r" | jq -r '.user.id // .id')
    log "created user $name ($uid)"
  fi
  have=$(body_of "$(api GET "/permissions?per_page=200")" | jq -r --arg u "$uid" --arg r "$rid" \
    '(if type=="array" then . else .items end)[] | select(.principal_id==$u and .target_id==$r) | .id' | head -1)
  if [[ -n "$have" ]]; then log "$name has its permission on agent-plugins"; else
    r=$(api POST /permissions -d "$(jq -nc --arg u "$uid" --arg r "$rid" --argjson a "$actions" \
        '{principal_type:"user",principal_id:$u,target_type:"repository",target_id:$r,actions:$a}')")
    [[ $(code_of "$r") =~ ^20 ]] || die "permission for $name failed: HTTP $(code_of "$r") $(body_of "$r")"
    log "granted $name $actions on agent-plugins"
  fi
  if works "$TOKENS/$name.token" agent-plugins; then log "$name.token still valid"; else
    ujwt=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
           -d "$(jq -nc --arg n "$name" --arg p "$(cat "$pwf")" '{username:$n,password:$p}')" | jq -r .access_token)
    [[ -n "$ujwt" && "$ujwt" != null ]] || die "$name login failed"
    mint_repo_token "$ujwt" agent-plugins "$tname" "$scopes" "$TOKENS/$name.token"
    log "minted $name.token (user $name, repository token on agent-plugins: $scopes, 30 days)"
  fi
}
ensure_user ci "CI publisher" '["read","write"]' ci-publish '["read:artifacts","write:artifacts"]'
ensure_user developer "A developer (read only)" '["read"]' developer-workstation '["read:artifacts"]'

# --- trust repo: the CA certificate -------------------------------------------
want=$(sha256sum "$CA" | cut -d' ' -f1)
have=$(akcurl -sS "$U/api/v1/repositories/trust/download/ak-internal-ca.crt" | sha256sum | cut -d' ' -f1)
if [[ "$have" == "$want" ]]; then log "trust/ak-internal-ca.crt up to date"; else
  api DELETE /repositories/trust/artifacts/ak-internal-ca.crt -o /dev/null >/dev/null || true
  r=$(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $JWT" -H 'Content-Type: application/x-pem-file' \
        -X PUT --data-binary "@$CA" "$U/api/v1/repositories/trust/artifacts/ak-internal-ca.crt")
  [[ "$r" =~ ^20 ]] || die "CA upload failed: HTTP $r"
  log "uploaded trust/ak-internal-ca.crt"
fi
log "done. Tokens in $TOKENS (never commit). CA: $CA"
