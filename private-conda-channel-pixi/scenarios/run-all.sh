#!/usr/bin/env bash
# Run every scenario (or the ones named: scenarios/run-all.sh S1 S4) and print this run's
# verdicts. AM=nexus (default) runs s<N>-*.sh, AM=proget the s<N>-*-proget.sh variants
# (S1 S2 S3 S4 S6; S5 and S7 are about Artifact Keeper alone).
# Each scenario restores what it changed on ak-conda before it exits; a failing
# scenario does not stop the others. Logs: ~/.cache/ak-scenarios/<id>-<name>.log;
# verdicts accumulate in ~/.cache/ak-scenarios/results.tsv.
# Exit 1 when any check FAILed (BLOCKED is not a failure: it names an unlanded fix).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
start=$(date -u +%FT%TZ); t0=$SECONDS
sel=("$@"); ((${#sel[@]})) || { [[ $AM == proget ]] && sel=(S1 S2 S3 S4 S6) || sel=(S1 S2 S3 S4 S5 S6 S7); }
for s in "${sel[@]}"; do
  p="$HERE/$(tr 'S' 's' <<<"${s^^}")"
  if [[ $AM == nexus ]]; then f=$(ls "$p"-*.sh 2>/dev/null | grep -v -- '-proget\.sh$' | head -1)
  else f=$(ls "$p"-*-"$AM".sh 2>/dev/null | head -1); fi
  [[ -n $f ]] || { echo "no scenario $s for AM=$AM"; continue; }
  echo "=== $(basename "$f")"
  t=$SECONDS; AM=$AM bash "$f" 2>&1 | grep -E '^(PASS|FAIL|BLOCKED)'; echo "    ($((SECONDS - t)) s, log $SCN_OUT/$(basename "$f" .sh | sed -E 's/^s([0-9])-/S\1-/').log)"
done
echo; echo "Summary, AM=$AM ($start .. $(date -u +%FT%TZ), $((SECONDS - t0)) s):"
awk -F'\t' -v s="$start" '$1 >= s {printf "  %-12s %-4s %s\n", $2, $3, $4}' "$SCN_RESULTS"
awk -F'\t' -v s="$start" '$1 >= s && $2 == "FAIL" {f=1} END {exit f}' "$SCN_RESULTS"
