#!/usr/bin/env bash
# (Re)start the lab upstream at 172.31.50.200:8080 on ak-agent-net. A restart makes its
# "fresh" releases fresh again (publish times are relative to server start).
# The image is pulled from Docker Hub directly: this container is a test fixture, not
# part of what the agent consumes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
podman rm -f ak-agent-lab-upstream >/dev/null 2>&1 || true
podman run -d --name ak-agent-lab-upstream --network ak-agent-net --ip 172.31.50.200 \
  -v "$here/server.py:/srv/server.py:ro,z" docker.io/library/python:3.12-alpine \
  python -I /srv/server.py 8080 >/dev/null
for _ in $(seq 30); do
  podman logs ak-agent-lab-upstream 2>/dev/null | grep -q "lab-upstream on" && break; sleep 1
done
podman logs ak-agent-lab-upstream 2>&1 | head -1
