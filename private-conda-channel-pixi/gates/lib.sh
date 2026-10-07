# Helpers for the gate scripts. Source it.
# Each gate prints evidence, then exactly one verdict line per check:
#   PASS  Gn <check>
#   FAIL  Gn <check>: <why>
#   BLOCKED(Fx) Gn <check>: <why>    (depends on an unlanded Artifact Keeper fix)
# Verdicts are appended to out/gates/results.tsv.
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$GATES_DIR/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
U=$(AK_HOST_URL)
GOUT="$ROOT/out/gates"; mkdir -p "$GOUT"
RESULTS="$GOUT/results.tsv"
CLIENT=localhost/ak-conda/pixi-client:0.81.0
SP_TMP="$GOUT/tmp"; mkdir -p "$SP_TMP"
verdict() { # STATUS GATE CHECK [WHY]
  local line; line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "${4:-}")
  echo "$line" >> "$RESULTS"
  printf '%-12s %-4s %s%s\n' "$1" "$2" "$3" "${4:+: $4}"
}
pass()    { verdict PASS "$@"; }
fail()    { verdict FAIL "$@"; }
blocked() { local f=$1; shift; verdict "BLOCKED($f)" "$@"; }
admin_h() { echo "Authorization: Bearer $(admin_token)"; }
tok() { cat "$TOKENS/$1.token"; }
# http METHOD URL TOKEN-NAME|- [curl args] -> prints "<code>" and saves body to $SP_TMP/body
http() {
  local m=$1 url=$2 t=$3; shift 3; local H=()
  [[ "$t" != - ]] && H=(-H "Authorization: Bearer $( [[ $t == admin ]] && admin_token || tok "$t")")
  akcurl -sS -X "$m" "${H[@]}" -o "$SP_TMP/body" -w '%{http_code}' "$@" "$url"
}
body() { cat "$SP_TMP/body"; }
# run a command in the pixi client container: in_client NETWORK AUTH(token-name|-) cmd...
in_client() {
  local net=$1 auth=$2; shift 2; local A=()
  [[ "$auth" != - ]] && A=(-v "$TOKENS/$auth-auth.json:/run/secrets/rattler-auth.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json)
  podman run --rm --network "$net" "${A[@]}" ${CLIENT_ARGS:-} "$CLIENT" "$@"
}
# Caddy access log lines since a timestamp (unix seconds): method uri status
access_since() {
  podman logs ak-conda-caddy 2>&1 | grep '"uri"' | jq -r --argjson t "$1" \
    'select(.ts >= $t) | [.request.method, .request.uri, .status, ((.request.headers.Authorization // ["-"])[0])] | @tsv'
}
# Ensure a scratch repository exists (key json)
ensure_repo() {
  local key=$1 json=$2
  [[ $(http GET "$U/api/v1/repositories/$key" admin) == 200 ]] && return 0
  local c; c=$(http POST "$U/api/v1/repositories" admin -H 'Content-Type: application/json' -d "$json")
  [[ "$c" =~ ^20 ]] || { echo "ensure_repo $key: HTTP $c $(body)" >&2; return 1; }
}
# RATTLER_AUTH_FILE with the admin token, for gate-only scratch repositories that
# the consumer token's repository selector does not cover.
admin_auth_file() {
  (umask 077; jq -n --arg h "$AK_HOST" --arg t "$(admin_token)" '{($h):{BearerToken:$t}}' > "$SP_TMP/admin-auth.json")
  echo "$SP_TMP/admin-auth.json"
}
