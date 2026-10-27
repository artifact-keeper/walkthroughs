#!/usr/bin/env bash
# Stop the lab upstream.
podman rm -f ak-agent-lab-upstream >/dev/null 2>&1 || true
