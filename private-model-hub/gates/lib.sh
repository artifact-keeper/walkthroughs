# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the gate scripts. Source it. Builds on flows/lib.sh (call, code, show, hf, ...).
# Each gate prints evidence, then exactly one verdict line per check:
#   PASS             Gn <check>
#   FAIL             Gn <check>: <why>
#   BLOCKED(reason)  Gn <check>: <why>
# Reasons: network (huggingface.co is not reachable from the backend), ak-fix (an Artifact
# Keeper bug that is reported, not yet fixed; see the findings), ak-gap (a capability Artifact
# Keeper does not have; see the findings). Verdicts are appended to out/gates/results.tsv.
# Checks assert on HTTP status codes, headers, documents and file hashes, never on message text.
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../flows/lib.sh
source "$GATES_DIR/../flows/lib.sh"
GOUT="$ROOT/out/gates"; mkdir -p "$GOUT"
RESULTS="$GOUT/results.tsv"
RUNID=$(date +%s)   # unique model ids for the gates' own publishes: acme/g5-<RUNID>, ...
AK_HOSTED_SNAPSHOT_ISSUE=artifact-keeper#5280   # the hosted snapshot_download bug (gate G5)
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
# is CODE: the last call answered HTTP CODE
is() { [[ $(code) == "$1" ]]; }
why() { echo "HTTP $(code) $(head -c 160 "$FOUT/.body" | tr '\n' ' ')"; }
# ok FILE: the hfcheck JSON in FILE says ok
ok() { jq -e '.ok == true' "$1" >/dev/null 2>&1; }
hfwhy() { jq -c '{ok, error, status, msg: ((.msg // "") | .[0:120])}' "$1" 2>/dev/null || echo "no output"; }
