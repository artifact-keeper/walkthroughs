#!/usr/bin/env bash
# Stop the lab Hub.
set -euo pipefail
podman rm -f -t 0 --ignore ak-hf-lab-hub >/dev/null
