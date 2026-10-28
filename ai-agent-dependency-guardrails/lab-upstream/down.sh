#!/usr/bin/env bash
# Stop the lab upstream.
set -euo pipefail
podman rm -f -t 0 --ignore ak-agent-lab-upstream >/dev/null
