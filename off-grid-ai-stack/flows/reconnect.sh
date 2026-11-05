#!/usr/bin/env bash
# Undo make disconnect: back to ak-offgrid-seed, every Remote online, the jobs resumed.
# Used to re-seed (a new model, a new package) or before make clean; the gates do not need it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
podman rm -f -t 0 --ignore "$LLAMA" >/dev/null
"$ROOT/ledger/down.sh"
"$ROOT/registry/down.sh"   # down, then up on the seed network (see flows/disconnect.sh)
echo seed > "$PHASE_FILE"
load_env
"$ROOT/registry/up.sh"
"$ROOT/ledger/up.sh"
for r in "${REMOTES[@]}"; do
  api PUT "/repositories/$r/upstream-mode" -d '{"upstream_mode":"online"}' >/dev/null
  printf '  %-14s upstream-mode online: HTTP %s\n' "$r" "$(code)"
done
api PATCH /admin/settings/system -d '{"upstream_jobs_paused":false}' >/dev/null
echo "  upstream_jobs_paused false: HTTP $(code)"
