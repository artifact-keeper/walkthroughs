#!/usr/bin/env bash
# G10: from an empty registry, twice: make clean && make all && make gates.
# Writes out/reproduce.txt (kept by make clean) with the result and wall time of each run,
# and the full logs to out/reproduce-run<N>.log. Run 2 also proves every target re-runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"; mkdir -p out
rec="out/reproduce.txt"; : > "$rec.tmp"
for n in 1 2; do
  start=$SECONDS
  if make clean >"out/reproduce-run$n.log" 2>&1 && make all >>"out/reproduce-run$n.log" 2>&1 \
     && make gates >>"out/reproduce-run$n.log" 2>&1; then res=PASS; else res=FAIL; fi
  secs=$((SECONDS - start))
  echo "run $n: $res in $((secs / 60)) min $((secs % 60)) s ($(date -u +%FT%TZ) on $(hostname))" | tee -a "$rec.tmp"
  grep -E '^G[0-9]+ ' "out/gates/summary.txt" 2>/dev/null | sed 's/^/  /' >> "$rec.tmp"
done
mv "$rec.tmp" "$rec"
make gates >/dev/null 2>&1 || true   # once more, so G10 reports on both runs
grep '^G10' out/gates/summary.txt
