#!/usr/bin/env bash
# Run every gate (or the ones named: gates/run-all.sh g01 g07) and print a summary
# table of this run's verdicts. Results accumulate in out/gates/results.tsv;
# each gate's full output goes to out/gates/<gate>.log.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
start=$(date -u +%FT%TZ)
sel=("$@"); ((${#sel[@]})) || sel=(g01 g02 g03 g04 g05 g06 g07 g08 g09 g10 g11 g12 g13 g14)
for g in "${sel[@]}"; do
  s=$(ls "$HERE/$g"-*.sh 2>/dev/null | head -1); [[ -n "$s" ]] || { echo "no gate $g"; continue; }
  echo "=== $(basename "$s")"
  t0=$SECONDS; bash "$s" 2>&1 | tee "$GOUT/$g.log" | grep -E '^(PASS|FAIL|BLOCKED)'; echo "    ($((SECONDS - t0)) s, log out/gates/$g.log)"
done
echo; echo "Summary ($start .. $(date -u +%FT%TZ)):"
awk -F'\t' -v s="$start" '$1 >= s {printf "  %-12s %-4s %s\n", $2, $3, $4}' "$RESULTS"
