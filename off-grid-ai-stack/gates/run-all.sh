#!/usr/bin/env bash
# Run every gate (or the ones named: gates/run-all.sh g01 g05) and print a summary table of
# this run's verdicts. Results accumulate in out/gates/results.tsv; each gate's full output
# goes to out/gates/<gate>.log and its duration to out/gates/timings.tsv.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
start=$(date -u +%FT%TZ); t_all=$SECONDS
sel=("$@"); ((${#sel[@]})) || sel=(g01 g02 g03 g04 g05 g06 g07)
for g in "${sel[@]}"; do
  s=$(ls "$HERE/$g"-*.sh 2>/dev/null | head -1); [[ -n "$s" ]] || { echo "no gate $g"; continue; }
  echo "=== $(basename "$s")"
  t0=$SECONDS; bash "$s" 2>&1 | tee "$GOUT/$g.log" | grep -E '^(PASS|FAIL|BLOCKED)'
  printf '%s\t%s\t%s\n' "$start" "$g" "$((SECONDS - t0))" >> "$GOUT/timings.tsv"
  echo "    ($((SECONDS - t0)) s, log out/gates/$g.log)"
done
echo; echo "Summary ($start .. $(date -u +%FT%TZ), $((SECONDS - t_all)) s):"
awk -F'\t' -v s="$start" '$1 >= s {printf "  %-17s %-4s %s%s\n", $2, $3, $4, ($5 != "" ? ": " $5 : "")}' "$RESULTS"
awk -F'\t' -v s="$start" '$1 >= s {n[$2]++} END {for (k in n) printf "  %s %d\n", k, n[k]}' "$RESULTS" | sort
! awk -F'\t' -v s="$start" '$1 >= s && $2 == "FAIL"' "$RESULTS" | grep -q .
