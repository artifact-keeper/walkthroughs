# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the gate scripts. Source it. Builds on flows/lib.sh (call, code, show, enc, ...).
# Each gate prints evidence, then exactly one verdict line per check:
#   PASS             Gn <check>
#   FAIL             Gn <check>: <why>
#   BLOCKED(reason)  Gn <check>: <why>
# Reasons: gui (a check that needs a person in VS Code or GitHub; the line says what to do),
# ak-fix (an Artifact Keeper bug that is reported, not yet fixed; see findings). Verdicts are
# appended to out/gates/results.tsv. Checks assert on HTTP status codes, error codes and
# documents, never on message text.
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../flows/lib.sh
source "$GATES_DIR/../flows/lib.sh"
GOUT="$ROOT/out/gates"; mkdir -p "$GOUT"
RESULTS="$GOUT/results.tsv"
RUNID=$(date +%s)   # unique versions for the gates' own publishes: 0.<RUNID>.0
verdict() { # STATUS GATE CHECK [WHY]
  local line; line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "${4:-}")
  echo "$line" >> "$RESULTS"
  printf '%-17s %-4s %s%s\n' "$1" "$2" "$3" "${4:+: $4}"
}
pass()    { verdict PASS "$@"; }
fail()    { verdict FAIL "$@"; }
blocked() { local r=$1; shift; verdict "BLOCKED($r)" "$@"; }
check()   { # check GATE NAME WHY-IF-FAILED condition-command...
  local g=$1 n=$2 why=$3; shift 3
  if "$@"; then pass "$g" "$n"; else fail "$g" "$n" "$why"; fi
}
# is CODE [ERROR]: the last call answered HTTP CODE (and problem+json .error ERROR)
is() {
  [[ $(code) == "$1" ]] || return 1
  [[ -z ${2:-} ]] || [[ $(jq -r '.error // .code // empty' "$FOUT/.body" 2>/dev/null) == "$2" ]]
}
# plain404: the last body is byte for byte the unknown-name answer
PLAIN404='{"detail":"Server not found","status":404,"title":"Not Found","type":"about:blank"}'
plain404() { [[ $(code) == 404 && $(cat "$FOUT/.body") == "$PLAIN404" ]]; }
why() { echo "HTTP $(code) $(head -c 200 "$FOUT/.body")"; }
