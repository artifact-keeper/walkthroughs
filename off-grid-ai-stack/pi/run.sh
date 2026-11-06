#!/usr/bin/env bash
# Run a command in the pi image on the network the stack is on now (the site network after
# make disconnect), as the developer, with the home out/homes/pi (kept between runs; make pi
# starts it afresh).
#   pi/run.sh command [args...]      for example: pi/run.sh pi mcp list
# The developer token reaches the container as AK_TOKEN, through the environment only (the
# bridge uses it; pi itself does not talk to Artifact Keeper). pi reaches the model as
# http://ak-offgrid-llama:8080/v1 (out/homes/pi/.pi/agent/models.json).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
load_env
H="$ROOT/out/homes/pi"; mkdir -p "$H"
AK_TOKEN="$(tok developer)"; export AK_TOKEN
exec podman run --rm -i --network "$NET" --userns keep-id:uid=1000,gid=1000 \
  -e AK_TOKEN -e AK_URL="$AK_URL" -v "$H:/home/dev:z" -w /home/dev localhost/ak-offgrid/pi:latest "$@"
