#!/usr/bin/env bash
# make scenarios-restore: put back what a killed scenario run left changed on ak-conda.
# Each scenario journals its restore commands in .work/pending/ before it changes the
# allowlist, the conda-forge upstream URL or scan config, or stops the backend, and removes
# the entry once its trap has restored it. A run killed with SIGKILL (no trap) leaves the
# entry; this script (and the next scenario's start) replays it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SID=restore
n=$(ls "$PENDING"/*.sh 2>/dev/null | wc -l)
(( n )) || { log "nothing pending"; exit 0; }
replay_pending
