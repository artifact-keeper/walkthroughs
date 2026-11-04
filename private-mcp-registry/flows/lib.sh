# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the flow scripts (make publish, clients, curate, ...) and the gates. Source it.
FLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../registry/lib.sh
source "$FLOWS_DIR/../registry/lib.sh"
load_env
U=$(AK_HOST_URL)
RUN="$ROOT/client/run.sh"
FOUT="$ROOT/out/flows"; mkdir -p "$FOUT"
SCHEMA=https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json
REG=/mcp/mcp-internal/v0.1          # the private registry's API root
UP=/mcp/mcp-upstream/v0.1           # the curated proxy's API root
CAT=/api/v1/repositories/mcp-upstream/mcp   # its management API

say() { printf '\n== %s\n' "$*"; }
# call WHO METHOD PATH [curl args]: WHO is admin, a token name (ci, developer) or - (anonymous).
# Prints the body; the HTTP status goes to $FOUT/.code.
call() {
  local who=$1 m=$2 p=$3; shift 3; local H=()
  case $who in
    -) ;;
    admin) H=(-H "Authorization: Bearer $(admin_token)") ;;
    *) H=(-H "Authorization: Bearer $(tok "$who")") ;;
  esac
  akcurl -sS -X "$m" "${H[@]}" -H 'Content-Type: application/json' -o "$FOUT/.body" -w '%{http_code}' "$@" "$U$p" > "$FOUT/.code"
  cat "$FOUT/.body"
}
code() { cat "$FOUT/.code"; }
# show WHO METHOD PATH [curl args]: like call, then print "HTTP <status>" and the body (jq-compact)
show() {
  call "$@" >/dev/null
  echo "HTTP $(code)"; jq -c . "$FOUT/.body" 2>/dev/null || cat "$FOUT/.body"; echo
}
# enc NAME: a server name for a URL path (com.acme/tickets -> com.acme%2Ftickets)
enc() { jq -rn --arg n "$1" '$n | @uri'; }
# cid NAME: the catalog id of a server name on mcp-upstream
cid() { call admin GET "$CAT/catalog/servers/$1" | jq -r .id; }
# repo_id KEY / user_id NAME
repo_id() { call admin GET "/api/v1/repositories/$1" | jq -r .id; }
user_id() { call admin GET "/api/v1/users?per_page=200" | jq -r --arg n "$1" '(if type == "array" then . else .items end)[] | select(.username == $n) | .id'; }
# grant_read USER REPO: an unconditioned read rule (idempotent)
grant_read() {
  local uid rid have
  uid=$(user_id "$1"); rid=$(repo_id "$2")
  have=$(call admin GET "/api/v1/permissions?per_page=500" | jq -r --arg u "$uid" --arg r "$rid" \
    '(if type == "array" then . else .items end)[] | select(.principal_id == $u and .target_id == $r) | .id' | head -1)
  [[ -n $have ]] && return 0
  call admin POST /api/v1/permissions -d "$(jq -nc --arg u "$uid" --arg r "$rid" \
    '{principal_type:"user",principal_id:$u,target_type:"repository",target_id:$r,actions:["read"]}')" >/dev/null
  echo "granted $1 read on $2 (HTTP $(code))"
}
# ensure_repo KEY JSON: create a repository unless it exists
ensure_repo() {
  call admin GET "/api/v1/repositories/$1" >/dev/null
  if [[ $(code) == 200 ]]; then echo "repository $1 exists"; return; fi
  call admin POST /api/v1/repositories -d "$2" >/dev/null
  [[ $(code) =~ ^20 ]] || { echo "creating $1 failed: HTTP $(code) $(cat "$FOUT/.body")" >&2; return 1; }
  echo "repository $1 created: $(jq -c '{format,repo_type,visibility}' "$FOUT/.body")"
}
# audit ACTION-REGEX [N]: the newest audit events whose action matches
audit() {
  call admin GET "/api/v1/admin/audit?per_page=${2:-100}" | jq -c --arg re "$1" \
    '.items[] | select(.action | test($re)) | {action, actor: .actor_username, details}'
}
# NPMRC: a shell line, run in the workstation, that writes ~/.npmrc with $AK_TOKEN for the three
# npm repositories (npm matches a token to a registry by its exact URL prefix)
NPMRC='for r in npm-internal npm npm-remote; do printf "//ak.internal/npm/%s/:_authToken=\${AK_TOKEN}\n" $r; done > ~/.npmrc'
