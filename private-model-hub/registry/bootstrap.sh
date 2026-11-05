#!/usr/bin/env bash
# Idempotently configure the ak-hf registry for the walkthrough.
#
# Repositories created here (the step scripts add the rest; see flows/):
#   oci-dockerhub  docker, Remote   https://registry-1.docker.io (the workstation's base image)
#   pypi-remote    pypi,   Remote   https://pypi.org (huggingface_hub, transformers, ...)
#   pypi-torch     pypi,   Remote   https://download.pytorch.org/whl/cpu (CPU-only torch; a
#                                   flat index, pypi_upstream_index_path "")
#   hf-hub         huggingface, Remote, private   https://huggingface.co
#   hf-lab         huggingface, Remote, private   the lab Hub (http://<LAB_IP>:8080)
# Both Hub Remotes are frozen at creation: cache-ttl 315360000 s, on-upstream-not-found keep.
# The three package proxies are "internal" (any signed-in user reads them); every
# huggingface repository is private (read needs an explicit grant).
#
# Users and tokens (in registry/.tokens/, gitignored, mode 600):
#   admin.token      admin API token for the scripts (30 days)
#   developer.token  user developer: read on every huggingface repository except the gated
#                    one. Scope read:artifacts (what HF_TOKEN holds on a workstation)
#   publisher.token  user publisher: read and write on the hosted repositories (step 5).
#                    Scopes read:artifacts, write:artifacts (a training pipeline's token)
#   publisher-read.token  the same user, scope read:artifacts only
#   alice.token      user alice, in group ml-team, which alone may read hf-lab-gated (step 3)
#   bob.token        user bob: read on hf-lab only, not in ml-team
# plus a podman auth file developer-podman.json for the base-image pull from the host.
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
  log "repo $key created: $(body_of "$r" | jq -c '{format,repo_type,visibility,upstream_url}')"
}
create_repo oci-dockerhub '{"key":"oci-dockerhub","name":"Docker Hub (proxy)","format":"docker",
  "repo_type":"remote","upstream_url":"https://registry-1.docker.io","visibility":"internal"}'
create_repo pypi-remote '{"key":"pypi-remote","name":"PyPI (proxy)","format":"pypi",
  "repo_type":"remote","upstream_url":"https://pypi.org","visibility":"internal"}'
create_repo pypi-torch '{"key":"pypi-torch","name":"PyTorch CPU wheels (proxy)","format":"pypi",
  "repo_type":"remote","upstream_url":"https://download.pytorch.org/whl/cpu","visibility":"internal",
  "pypi_upstream_index_path":""}'
create_repo hf-hub '{"key":"hf-hub","name":"huggingface.co through Artifact Keeper","format":"huggingface",
  "repo_type":"remote","upstream_url":"https://huggingface.co","visibility":"private"}'
create_repo hf-lab "$(jq -nc --arg u "http://$LAB_IP:8080" '{key:"hf-lab",name:"The lab Hub (stands in for huggingface.co)",
  format:"huggingface",repo_type:"remote",upstream_url:$u,visibility:"private"}')"
rid() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }
# Freeze the two Hub Remotes before anything is cached (step 7 explains why now): mutable
# paths (revision/main, resolve/main/...) never revalidate, and an upstream 404 never evicts
# a cached file. A raised cache-ttl applies to an entry only from its next revalidation, so
# setting it after the first pull leaves the early entries on the 300 s default.
for r in hf-hub hf-lab; do
  r1=$(api PUT "/repositories/$r/cache-ttl" -d '{"cache_ttl_seconds":315360000}')
  r2=$(api PUT "/repositories/$r/on-upstream-not-found" -d '{"on_upstream_not_found":"keep"}')
  [[ $(code_of "$r1") == 200 && $(code_of "$r2") == 200 ]] || die "freezing $r failed: $(body_of "$r1") $(body_of "$r2")"
  log "repo $r: cache_ttl_seconds 315360000, on_upstream_not_found keep"
done

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

ensure_user developer "A developer (read only)" '["read:artifacts"]'
for r in hf-hub hf-lab; do grant "$USER_ID" "$r" '["read"]'; done
ensure_user publisher "Model publisher (training pipeline)" '["read:artifacts","write:artifacts"]'
# A second token of the same user with read:artifacts only: write permission on a repository
# is not enough to upload without the write:artifacts scope (gate G5).
if ! works "$TOKENS/publisher-read.token"; then
  pjwt=$(akcurl -fsS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' \
         -d "$(jq -nc --arg p "$(cat "$TOKENS/publisher.password")" '{username:"publisher",password:$p}')" | jq -r .access_token)
  (umask 077; akcurl -fsS -X POST "$U/api/v1/auth/tokens" -H "Authorization: Bearer $pjwt" -H 'Content-Type: application/json' \
     -d '{"name":"publisher-read","scopes":["read:artifacts"],"expires_in_days":30}' | jq -r .token > "$TOKENS/publisher-read.token")
  log "minted publisher-read.token (user publisher, scopes [\"read:artifacts\"], 30 days)"
fi
ensure_user alice "Alice (ml-team)" '["read:artifacts"]'
ensure_user bob "Bob (not in ml-team)" '["read:artifacts"]'
grant "$USER_ID" hf-lab '["read"]'

# --- podman on the host: the workstation's base image through oci-dockerhub ----
# The host cannot resolve ak.internal; it uses the loopback port by the name localhost,
# for which Caddy issues a certificate from the same internal CA.
CERTS="$OUT/certs.d/localhost:${HTTPS_PORT}"
mkdir -p "$CERTS"; cp "$CA" "$CERTS/ca.crt"
podman login --cert-dir "$CERTS" --authfile "$TOKENS/developer-podman.json" -u developer --password-stdin \
  "localhost:${HTTPS_PORT}" < "$TOKENS/developer.token" >/dev/null || die "podman login failed"
log "podman auth (developer): $TOKENS/developer-podman.json"

log "done. Tokens in $TOKENS (never commit). CA: $CA"
