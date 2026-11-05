#!/usr/bin/env bash
# (Re)start the lab Hub at http://LAB_IP:8080 (.200 on ak-hf-net), also reachable as cdn.lab
# (its "CDN" for large files). The gated model's token is generated once into
# registry/.tokens/lab-hub.token (gitignored) and handed to the server through the
# environment. The image is pulled from Docker Hub directly: this container is a test
# fixture standing in for huggingface.co, not part of what clients use.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
load_env
"$here/down.sh"
mkdir -p "$TOKENS"; chmod 700 "$TOKENS"
if [[ ! -s "$TOKENS/lab-hub.token" ]]; then
  (umask 077; echo "hf_lab$(openssl rand -hex 16)" > "$TOKENS/lab-hub.token")
fi
LAB_HUB_TOKEN=$(<"$TOKENS/lab-hub.token") podman run -d --name ak-hf-lab-hub --network "$NET" --ip "$LAB_IP" \
  --network-alias cdn.lab --network-alias hub.lab -e LAB_HUB_TOKEN \
  -v "$here/server.py:/srv/server.py:ro,z" \
  docker.io/library/python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0 \
  python -I /srv/server.py 8080 >/dev/null
for _ in $(seq 30); do
  podman logs ak-hf-lab-hub 2>/dev/null | grep -q '"lab-hub on"' && break; sleep 1
done
podman logs ak-hf-lab-hub 2>&1 | head -1
echo "lab-hub: http://$LAB_IP:8080 (alias cdn.lab)"
