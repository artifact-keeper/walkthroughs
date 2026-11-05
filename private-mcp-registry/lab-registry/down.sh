#!/usr/bin/env bash
# Stop the lab upstream registry.
set -euo pipefail
podman rm -f -t 0 --ignore ak-mcp-lab-registry >/dev/null
