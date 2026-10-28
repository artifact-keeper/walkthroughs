#!/usr/bin/env bash
# (Re)start the lab upstream at LAB_IP:8080 (.200 on ak-agent-net). Publish times are
# relative to each request, so its "fresh" releases are always minutes old.
# The image is pulled from Docker Hub directly: this container is a test fixture, not
# part of what the agent consumes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
load_env
"$here/down.sh"
podman run -d --name ak-agent-lab-upstream --network ak-agent-net --ip "$LAB_IP" \
  -v "$here/server.py:/srv/server.py:ro,z" \
  docker.io/library/python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0 \
  python -I /srv/server.py 8080 >/dev/null
for _ in $(seq 30); do
  podman logs ak-agent-lab-upstream 2>/dev/null | grep -q "lab-upstream on" && break; sleep 1
done
podman logs ak-agent-lab-upstream 2>&1 | head -1
