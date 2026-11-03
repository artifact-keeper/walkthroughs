# Helpers for the gate scripts. Source it.
# Each gate prints evidence, then exactly one verdict line per check:
#   PASS  Gn <check>
#   FAIL  Gn <check>: <why>
#   BLOCKED(#issue) Gn <check>: <why>    (depends on an unmerged Artifact Keeper fix)
# Verdicts are appended to out/gates/results.tsv; evidence to out/gates/<gate>.txt.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../policy/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOUT="$ROOT/out/gates"; mkdir -p "$GOUT"
RESULTS="$GOUT/results.tsv"
PROBE="$ROOT/clients/probe.sh"
RUN="$ROOT/clients/run.sh"
verdict() { # STATUS GATE CHECK [WHY]
  local line; line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "${4:-}")
  echo "$line" >> "$RESULTS"
  printf '%-16s %-4s %s%s\n' "$1" "$2" "$3" "${4:+: $4}"
}
pass()    { verdict PASS "$@"; }
fail()    { verdict FAIL "$@"; }
blocked() { local i=$1; shift; verdict "BLOCKED($i)" "$@"; }
# evidence GATE "text...": appended to out/gates/<gate>.txt and echoed indented
evidence() { local g=$1; shift; printf '%s\n' "$@" | tee -a "$GOUT/$g.txt" | sed 's/^/    /'; }
# http METHOD URL [curl args] -> prints "<code>" and saves body to $GOUT/body (admin token)
http() {
  local m=$1 url=$2; shift 2
  akcurl -sS -X "$m" -H "Authorization: Bearer $ADMIN" -o "$GOUT/body" -w '%{http_code}' "$@" "$url"
}
body() { cat "$GOUT/body"; }
# The last line of a client log: "baseline npm: exit 0 in 12s"
log_exit() { tail -1 "$1" 2>/dev/null | sed -n 's/.*: exit \([0-9]*\) in.*/\1/p'; }
proxy_scan_entry() { # REPO PATH-REGEX -> the matching proxy-scan item (json) or empty
  body_of "$(api GET "/repositories/$1/security/proxy-scans?per_page=500&include_findings=true")" | jq -c --arg p "$2" '.items[] | select(.path | test($p))' | head -1
}
