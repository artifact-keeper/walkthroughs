#!/usr/bin/env bash
# Stop the ak-conda stack. Volumes are kept; pass --volumes to wipe all data.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
if [[ "${1:-}" == --volumes ]]; then compose down --volumes; else compose down; fi
