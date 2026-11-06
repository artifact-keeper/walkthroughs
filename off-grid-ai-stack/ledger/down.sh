#!/usr/bin/env bash
# Stop the egress ledger (its file, out/ledger/ledger.jsonl, is kept).
set -euo pipefail
podman rm -f -t 0 --ignore ak-offgrid-ledger >/dev/null
