# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the gate scripts. Source it. Builds on flows/lib.sh (call, code, api, metric, ...).
# Each gate prints evidence, then exactly one verdict line per check:
#   PASS             Gn <check>
#   FAIL             Gn <check>: <why>
#   BLOCKED(reason)  Gn <check>: <why>
# Reasons: network (huggingface.co or another upstream was not reachable while seeding),
# ak-fix (an Artifact Keeper bug that is reported, not yet fixed; see the findings), ak-gap (a
# capability Artifact Keeper does not have; see the findings), best-effort (the Claude Code
# step's model session, which is shown, not promised). Verdicts are appended to
# out/gates/results.tsv. Checks assert on HTTP status codes, documents, digests, hashes,
# counters and audit rows, never on message text.
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../flows/lib.sh
source "$GATES_DIR/../flows/lib.sh"
GOUT="$ROOT/out/gates"; mkdir -p "$GOUT"
RESULTS="$GOUT/results.tsv"
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
is() { [[ $(code) == "$1" ]]; }
need_site() { [[ $(phase) == site ]] || { echo "this gate runs on the site network: make disconnect first" >&2; exit 2; }; }
# ms CMD...: run CMD, print the milliseconds it took on fd 3
ms_of() { local s; s=$(date +%s%N); "$@" >/dev/null; echo $(( ($(date +%s%N) - s) / 1000000 )); }
DISC="$ROOT/out/disconnect.json"
