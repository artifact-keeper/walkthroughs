#!/usr/bin/env bash
# Print the HTTP status each credential gets on each consumer-relevant URL.
# Credentials: anonymous, ci (repo token on conda-staging), consumer (user token
# with a repo selector), consumer-repo (repo token on conda-virtual).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"; load_env
U=$(AK_HOST_URL)
PATHS=(
  conda/conda-internal/noarch/repodata.json
  conda/conda-staging/noarch/repodata.json
  conda/conda-forge/linux-64/libzlib-1.3.1-hb9d3cd8_2.conda
  conda/conda-virtual/linux-64/libzlib-1.3.1-hb9d3cd8_2.conda
  pypi/pypi-remote/simple/rich/
  api/v1/repositories/trust/download/ak-internal-ca.crt
)
printf '%-14s' credential; for p in "${PATHS[@]}"; do printf ' %s' "$(cut -d/ -f2 <<<"$p")"; done; echo
for t in anon ci consumer consumer-repo; do
  H=(); [[ $t != anon ]] && H=(-H "Authorization: Bearer $(<"$TOKENS/$t.token")")
  printf '%-14s' "$t"
  for p in "${PATHS[@]}"; do printf ' %s' "$(akcurl -sS -o /dev/null -w '%{http_code}' "${H[@]}" "$U/$p")"; done; echo
done
