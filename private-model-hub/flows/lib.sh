# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the flow scripts (make proxy, gated, allowlist, ...) and the gates. Source it.
FLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../registry/lib.sh
source "$FLOWS_DIR/../registry/lib.sh"
load_env
U=$(AK_HOST_URL)
RUN="$ROOT/client/run.sh"
FOUT="$ROOT/out/flows"; mkdir -p "$FOUT"
HFAPI=/huggingface                       # every repository's Hub API root is $HFAPI/<repo>
LAB_MODEL=acme-lab/tiny-st               # the lab Hub's public model
HUB_MODEL=sentence-transformers/all-MiniLM-L6-v2   # the real one, on huggingface.co
HUB_FILES=(--allow '*.json' --allow '*.txt' --allow model.safetensors)  # ~90 MB of it

say() { printf '\n== %s\n' "$*"; }
# call WHO METHOD PATH [curl args]: WHO is admin, a token name (developer, publisher, alice,
# bob), - (anonymous) or raw:<token> (a literal bearer token). Prints the body; the HTTP status
# goes to $FOUT/.code and the response headers to $FOUT/.headers.
call() {
  local who=$1 m=$2 p=$3; shift 3; local H=() mflag=(-X "$m")
  case $who in
    -) ;;
    admin) H=(-H "Authorization: Bearer $(admin_token)") ;;
    raw:*) H=(-H "Authorization: Bearer ${who#raw:}") ;;
    *) H=(-H "Authorization: Bearer $(tok "$who")") ;;
  esac
  [[ $m == HEAD ]] && mflag=(-I)
  akcurl -sS "${mflag[@]}" "${H[@]}" -D "$FOUT/.headers" -o "$FOUT/.body" -w '%{http_code}' "$@" "$U$p" > "$FOUT/.code"
  cat "$FOUT/.body"
}
code() { cat "$FOUT/.code"; }
hdr() { grep -i "^$1:" "$FOUT/.headers" | tail -1 | cut -d' ' -f2- | tr -d '\r'; }
# show WHO METHOD PATH [curl args]: like call, then print "HTTP <status>" and the body (jq-compact)
show() {
  call "$@" >/dev/null
  echo "HTTP $(code)"; jq -c . "$FOUT/.body" 2>/dev/null || head -c 300 "$FOUT/.body"; echo
}
# api METHOD PATH [curl args]: an admin call to /api/v1 with a JSON body
api() { local m=$1 p=$2; shift 2; call admin "$m" "/api/v1$p" -H 'Content-Type: application/json' "$@"; }
repo_id() { api GET "/repositories/$1" | jq -r .id; }
user_id() { api GET "/users?per_page=200" | jq -r --arg n "$1" '(if type == "array" then . else .items end)[] | select(.username == $n) | .id'; }
# ensure_repo KEY JSON: create a repository unless it exists
ensure_repo() {
  api GET "/repositories/$1" >/dev/null
  if [[ $(code) == 200 ]]; then echo "repository $1 exists"; return; fi
  api POST /repositories -d "$2" >/dev/null
  [[ $(code) =~ ^20 ]] || { echo "creating $1 failed: HTTP $(code) $(cat "$FOUT/.body")" >&2; return 1; }
  echo "repository $1 created: $(jq -c '{format,repo_type,visibility,upstream_url}' "$FOUT/.body")"
}
# grant PRINCIPAL_TYPE NAME REPO ACTIONS-JSON: a permission rule (idempotent)
grant() {
  local ptype=$1 pname=$2 repo=$3 actions=$4 pid rid have
  if [[ $ptype == group ]]; then pid=$(group_id "$pname"); else pid=$(user_id "$pname"); fi
  rid=$(repo_id "$repo")
  have=$(api GET "/permissions?per_page=500" | jq -r --arg u "$pid" --arg r "$rid" \
    '(if type == "array" then . else .items end)[] | select(.principal_id == $u and .target_id == $r) | .id' | head -1)
  [[ -n $have ]] && return 0
  api POST /permissions -d "$(jq -nc --arg t "$ptype" --arg u "$pid" --arg r "$rid" --argjson a "$actions" \
    '{principal_type:$t,principal_id:$u,target_type:"repository",target_id:$r,actions:$a}')" >/dev/null
  [[ $(code) =~ ^20 ]] || { echo "grant on $repo failed: HTTP $(code) $(cat "$FOUT/.body")" >&2; return 1; }
  echo "granted $ptype $pname $actions on $repo"
}
group_id() { api GET "/groups?per_page=200" | jq -r --arg n "$1" '.items[] | select(.name == $n) | .id'; }
# hf WHO REPO [-h HOME] [-o] -- hfcheck args: run client/hfcheck.py in the workstation with
# HF_ENDPOINT on REPO and HF_TOKEN = WHO's token (- for none). Prints its JSON line.
hf() {
  local who=$1 repo=$2; shift 2; local opts=(-r "$repo")
  [[ $who == - ]] || opts+=(-t "$who")
  while [[ $# -gt 0 && $1 != -- ]]; do opts+=("$1"); shift; done
  shift
  "$RUN" "${opts[@]}" -- python /client/hfcheck.py "$@" 2>"$FOUT/.hf-stderr" | tail -1
}
# metric REPO RESULT: the current value of ak_proxy_cache_lookups_total for one repository
metric() {
  call admin GET /api/v1/admin/metrics >/dev/null
  awk -v r="$1" -v s="$2" '$1 == "ak_proxy_cache_lookups_total{repository=\"" r "\",result=\"" s "\"}" {print $2; f=1} END {if (!f) print 0}' "$FOUT/.body"
}
# lab_log [SINCE]: the lab Hub's request log (JSON lines)
lab_log() { podman logs ${1:+--since "$1"} ak-hf-lab-hub 2>/dev/null | grep '^{"t"' || true; }
# fp TOKEN: the fingerprint the lab Hub logs for a bearer token
fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }
# hub_reachable: does the backend reach huggingface.co? Asks the backend itself
# (POST .../test-upstream on hf-hub). G2 reports BLOCKED(network) when it does not.
hub_reachable() {
  call admin POST /api/v1/repositories/hf-hub/test-upstream >/dev/null
  [[ $(code) == 200 ]] && jq -e '.status == "ok"' "$FOUT/.body" >/dev/null
}
# audit ACTION-REGEX [N]: the newest audit events whose action matches
audit() {
  api GET "/admin/audit?per_page=${2:-100}" | jq -c --arg re "$1" \
    '.items[] | select(.action | test($re)) | {action, actor: .actor_username, details}'
}
# disconnect / reconnect: take the upstreams away from Artifact Keeper, and give them back.
# The lab Hub stops; hf-hub's egress goes through a proxy address nothing listens on (the lab
# Hub's address, port 9), so every fetch from huggingface.co fails the way it fails on a
# disconnected network. Clients then run on ak-hf-offline (client/run.sh -o).
DEAD_PROXY_PORT=9
disconnect() {
  "$ROOT/lab-hub/down.sh"
  api PUT /repositories/hf-hub/egress-proxy -d "$(jq -nc --arg u "http://$LAB_IP:$DEAD_PROXY_PORT" '{mode:"explicit",proxy_url:$u}')" >/dev/null
  echo "disconnected: lab Hub stopped; hf-hub egress -> http://$LAB_IP:$DEAD_PROXY_PORT (HTTP $(code))"
}
reconnect() {
  api PUT /repositories/hf-hub/egress-proxy -d '{"mode":"inherit"}' >/dev/null
  "$ROOT/lab-hub/up.sh" >/dev/null
  echo "reconnected: lab Hub up; hf-hub egress inherit"
}
