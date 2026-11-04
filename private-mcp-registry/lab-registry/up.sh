#!/usr/bin/env bash
# (Re)start the lab upstream registry at http://LAB_IP:8080 (.200 on ak-mcp-net). It serves
# out/lab-registry/servers, a copy of lab-registry/servers made here, so a script can change
# the upstream (flows/drift.sh) without touching the committed fixtures. The image is pulled
# from Docker Hub directly: this container is a test fixture, not part of what clients use.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
load_env
"$here/down.sh"
state="$ROOT/out/lab-registry/servers"
rm -rf "$state"; mkdir -p "$state"
cp "$here"/servers/*.json "$state/"
podman run -d --name ak-mcp-lab-registry --network "$NET" --ip "$LAB_IP" \
  -v "$here/server.py:/srv/server.py:ro,z" -v "$state:/srv/servers:ro,z" \
  docker.io/library/python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0 \
  python -I /srv/server.py /srv/servers 8080 >/dev/null
for _ in $(seq 30); do
  podman logs ak-mcp-lab-registry 2>/dev/null | grep -q "lab-registry on" && break; sleep 1
done
podman logs ak-mcp-lab-registry 2>&1 | head -1
echo "lab-registry: $(ls "$state" | wc -l) server versions at http://$LAB_IP:8080"
