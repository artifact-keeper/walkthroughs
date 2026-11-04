#!/usr/bin/env bash
# G10: three runs, each `make all && make gates`:
#   run 1: after make clean (from an empty registry)
#   run 2: again, without make clean (every target re-runs on a populated stack)
#   run 3: after make clean again
# WARNING: make clean deletes the whole stack (containers, volumes, tokens, images it built).
# Writes out/reproduce.txt (kept by make clean) with the result, wall time and gate summary
# of each run, and the full logs to out/reproduce-run<N>.log. G10 passes only if all three do.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"; mkdir -p out
rec="out/reproduce.txt"; rm -f "$rec"; : > "$rec.tmp"
for n in 1 2 3; do
  log="out/reproduce-run$n.log"; : > "$log"; rm -rf out/gates
  start=$SECONDS
  { [[ $n == 2 ]] || make clean >>"$log" 2>&1; } && make all >>"$log" 2>&1 && make gates >>"$log" 2>&1 \
    && res=PASS || res=FAIL
  secs=$((SECONDS - start))
  what=$([[ $n == 2 ]] && echo "make all gates, no clean" || echo "make clean all gates")
  echo "run $n: $res in $((secs / 60)) min $((secs % 60)) s, $what ($(date -u +%FT%TZ) on $(hostname))" | tee -a "$rec.tmp"
  grep -E '^G[0-9]+ ' "out/gates/summary.txt" 2>/dev/null | sed 's/^/  /' >> "$rec.tmp"
done
mv "$rec.tmp" "$rec"
make gates >/dev/null 2>&1 || true   # once more, so G10 reports on all three runs
grep '^G10' out/gates/summary.txt
