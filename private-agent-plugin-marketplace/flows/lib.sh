# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the flow scripts (make publish, consume-claude, ...). Source it.
FLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../registry/lib.sh
source "$FLOWS_DIR/../registry/lib.sh"
load_env
U=$(AK_HOST_URL)
RUN="$ROOT/client/run.sh"
FOUT="$ROOT/out/flows"; mkdir -p "$FOUT"
REPO=agent-plugins
PUBLIC_REPO=agent-plugins-public

say()  { printf '\n== %s\n' "$*"; }
# adm PATH [curl args] : GET (or other) with the admin token; PATH starts with /
adm()  { local p=$1; shift; akcurl -sS -H "Authorization: Bearer $(admin_token)" "$@" "$U$p"; }
# code METHOD URL TOKEN-NAME|- [curl args] -> HTTP status, body in $FOUT/.body
code() {
  local m=$1 url=$2 t=$3; shift 3; local H=()
  [[ $t != - ]] && H=(-H "Authorization: Bearer $([[ $t == admin ]] && admin_token || tok "$t")")
  akcurl -sS -X "$m" "${H[@]}" -o "$FOUT/.body" -w '%{http_code}' "$@" "$url"
}
zip_path() { echo "$1/$2/$1-$2.zip"; }   # name version
# published REPO NAME VERSION: the version exists (servable 200, or held by a scan 403)
published() {
  local c; c=$(code HEAD "$U/agentplugins/$1/$(zip_path "$2" "$3")" admin -I)
  [[ $c == 200 || $c == 403 ]]
}
# listed REPO NAME VERSION: the version is in <name>/index.json (servable)
listed() {
  akcurl -fsS -H "Authorization: Bearer $(admin_token)" "$U/agentplugins/$1/$2/index.json" 2>/dev/null \
    | jq -e --arg v "$3" 'any(.versions[]; .version == $v)' >/dev/null
}
# wait_listed REPO NAME VERSION [TIMEOUT]: wait until the scan lets the version through
wait_listed() {
  local t0=$SECONDS limit=${4:-600}
  until listed "$1" "$2" "$3"; do
    (( SECONDS - t0 > limit )) && { echo "  $2 $3 not servable after ${limit}s" >&2; return 1; }
    sleep 3
  done
  echo "  $2 $3 servable in $1 after $((SECONDS - t0)) s"
}
# artifact_id REPO PATH
artifact_id() {
  adm "/api/v1/repositories/$1/artifacts?per_page=500" | jq -r --arg p "$2" '.items[] | select(.path == $p) | .id' | head -1
}
