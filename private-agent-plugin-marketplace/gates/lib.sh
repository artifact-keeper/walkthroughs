# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the gate scripts. Source it.
# Each gate prints evidence, then exactly one verdict line per check:
#   PASS  Gn <check>
#   FAIL  Gn <check>: <why>
#   BLOCKED(account) Gn <check>: <why>   (needs a signed-in agent account; the line says
#                                         what to run after logging in)
# Verdicts are appended to out/gates/results.tsv. Checks assert on HTTP status codes,
# exit codes and documents, never on message text.
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../registry/lib.sh
source "$GATES_DIR/../registry/lib.sh"; load_env
U=$(AK_HOST_URL)
RUN="$ROOT/client/run.sh"
GOUT="$ROOT/out/gates"; mkdir -p "$GOUT"
RESULTS="$GOUT/results.tsv"
G_TMP="$GOUT/tmp"; mkdir -p "$G_TMP"
MKZIP="$GATES_DIR/mkzip.py"
REPO=agent-plugins
verdict() { # STATUS GATE CHECK [WHY]
  local line; line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "${4:-}")
  echo "$line" >> "$RESULTS"
  printf '%-17s %-4s %s%s\n' "$1" "$2" "$3" "${4:+: $4}"
}
pass()    { verdict PASS "$@"; }
fail()    { verdict FAIL "$@"; }
blocked() { local f=$1; shift; verdict "BLOCKED($f)" "$@"; }
check()   { # check GATE NAME WHY-IF-FAILED condition-command...
  local g=$1 n=$2 why=$3; shift 3
  if "$@"; then pass "$g" "$n"; else fail "$g" "$n" "$why"; fi
}
admin_h() { echo "Authorization: Bearer $(admin_token)"; }
# http METHOD URL TOKEN-NAME|admin|- [curl args] -> prints the status; body in $G_TMP/body,
# headers in $G_TMP/headers
http() {
  local m=$1 url=$2 t=$3; shift 3; local H=()
  [[ $t != - ]] && H=(-H "Authorization: Bearer $([[ $t == admin ]] && admin_token || tok "$t")")
  akcurl -sS -X "$m" "${H[@]}" -D "$G_TMP/headers" -o "$G_TMP/body" -w '%{http_code}' "$@" "$url"
}
body() { cat "$G_TMP/body"; }
header() { grep -i "^$1:" "$G_TMP/headers" | head -1 | cut -d: -f2- | sed -e 's/^ *//' -e 's/\r$//'; }
# put_zip REPO NAME VERSION ZIP [TOKEN] [FILE] -> status of the native publish
put_zip() {
  local file=${6:-$2-$3.zip}
  http PUT "$U/agentplugins/$1/$2/$3/$file" "${5:-admin}" -H 'Content-Type: application/zip' --data-binary "@$4"
}
# fresh_repo KEY [VISIBILITY]: delete and recreate a scratch agentplugins repository, so a
# gate starts from nothing (immutability survives a version delete, not a repository delete)
fresh_repo() {
  local key=$1 vis=${2:-private} c
  http DELETE "$U/api/v1/repositories/$key" admin >/dev/null
  c=$(http POST "$U/api/v1/repositories" admin -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg k "$key" --arg v "$vis" '{key:$k,name:("gate scratch: "+$k),format:"agentplugins",repo_type:"local",visibility:$v}')")
  [[ $c =~ ^20 ]] || { echo "fresh_repo $key: HTTP $c $(body)" >&2; return 1; }
}
# claude_dir DIR NAME VERSION [DESCRIPTION]: a minimal Claude Code layout plugin
claude_dir() {
  rm -rf "$1"; mkdir -p "$1/.claude-plugin" "$1/skills/check"
  jq -n --arg n "$2" --arg v "$3" --arg d "${4:-gate fixture}" '{name:$n,version:$v,description:$d}' > "$1/.claude-plugin/plugin.json"
  printf -- '---\nname: check\ndescription: Gate fixture skill.\n---\n\nSay "%s %s".\n' "$2" "$3" > "$1/skills/check/SKILL.md"
}
# names DOC-FILE -> sorted "name@version" list, comma separated
names() { jq -r '[.plugins[] | "\(.name)@\(.version)"] | sort | join(",")' "$1"; }
