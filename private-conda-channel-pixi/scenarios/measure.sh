#!/usr/bin/env bash
# Run a command and summarise what went through the product and ak.internal meanwhile.
# Usage: scenarios/measure.sh nexus|proget LABEL cmd...
# Prints: exit code, wall time, requests/bytes served by the product to clients
# (by status), and requests/bytes the product (and anyone else) fetched from
# ak.internal (Caddy access log), by user agent.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P=$1 L=$2; shift 2
OUTD="$WORK/runs"; mkdir -p "$OUTD"
nlog() { [[ $P == nexus ]] && podman exec scn-nexus sh -c 'wc -l < /nexus-data/log/request.log' || echo 0; }
l0=$(nlog); t0=$(date +%s); s0=$SECONDS
"$@" > "$OUTD/$L.out" 2>&1; rc=$?
dt=$((SECONDS - s0)); sleep 1
echo "== $L: exit $rc, $dt s"
grep -v '^ WARN' "$OUTD/$L.out" | tail -${TAIL:-4}
if [[ $P == nexus ]]; then
  podman exec scn-nexus tail -n +$((l0 + 1)) /nexus-data/log/request.log | awk '$7 ~ /^\/repository\// { n[$9]++; b[$11 == "-" ? 0 : $9]+=$11 }
    END { for (s in n) printf "  product -> client: HTTP %s x%d, %.1f MB\n", s, n[s], b[s]/1e6 }'
  [[ -n "${SHOW_404:-}" ]] && podman exec scn-nexus tail -n +$((l0 + 1)) /nexus-data/log/request.log | awk '$7 ~ /^\/repository\// && $9 != 200 {print "    " $9, $7}' | sort | uniq -c
fi
podman logs ak-conda-caddy 2>&1 | grep '"uri"' | jq -r --argjson t "$t0" 'select(.ts >= $t) | [((.request.headers["User-Agent"]//["-"])[0] | split("/")[0]), .status, .size] | @tsv' |
  awk -F'\t' '{k=$1" HTTP "$2; n[k]++; b[k]+=$3} END {for (k in n) printf "  ak.internal -> %s x%d, %.1f MB\n", k, n[k], b[k]/1e6}'
