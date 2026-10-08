#!/usr/bin/env bash
# Run every scenario (or the ones named: scenarios/run-all.sh S1 S4) and print this run's
# verdicts. Each scenario restores what it changed on ak-conda before it exits; a failing
# scenario does not stop the others. Logs: ~/.cache/ak-scenarios/<id>-<name>.log;
# verdicts accumulate in ~/.cache/ak-scenarios/results.tsv.
# Exit 1 when any check FAILed (BLOCKED is not a failure: it names an unlanded fix).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
start=$(date -u +%FT%TZ); t0=$SECONDS
sel=("$@"); ((${#sel[@]})) || sel=(S1 S2 S3 S4 S5 S6 S7)
for s in "${sel[@]}"; do
  f=$(ls "$HERE/$(tr 'S' 's' <<<"${s^^}")"-*.sh 2>/dev/null | head -1); [[ -n $f ]] || { echo "no scenario $s"; continue; }
  echo "=== $(basename "$f")"
  t=$SECONDS; bash "$f" 2>&1 | grep -E '^(PASS|FAIL|BLOCKED)'; echo "    ($((SECONDS - t)) s, log $SCN_OUT/$(basename "$f" .sh | sed -E 's/^s([0-9])-/S\1-/').log)"
done
echo; echo "Summary ($start .. $(date -u +%FT%TZ), $((SECONDS - t0)) s):"
awk -F'\t' -v s="$start" '$1 >= s {printf "  %-12s %-4s %s\n", $2, $3, $4}' "$SCN_RESULTS"
awk -F'\t' -v s="$start" '$1 >= s && $2 == "FAIL" {f=1} END {exit f}' "$SCN_RESULTS"
