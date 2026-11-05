#!/usr/bin/env bash
# Take the web UI screenshots used in the docs, into out/screens/ (optional; not part of
# make all). Runs Playwright's image on ak-mcp-net, so the browser reaches
# https://ak.internal like every other client. The admin password comes from registry/.env;
# the package ids of the servers it opens come from the API.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
IMG=mcr.microsoft.com/playwright:v1.49.1-noble
pkg_id() { # server name -> the /api/v1/packages id of its row
  akcurl -fsS -H "Authorization: Bearer $(admin_token)" "$(AK_HOST_URL)/api/v1/packages?format=mcp&per_page=100" \
    | jq -r --arg n "$1" '(if type == "array" then . else .items end)[] | select(.name == $n and .repository_key == "mcp-internal") | .id' | head -1
}
TICKETS=$(pkg_id com.acme/tickets)
export TICKETS
mkdir -p "$ROOT/out/screens" "$ROOT/out/screens/.npm"
PW="$ADMIN_PASSWORD" podman run --rm --network "$NET" -e PW -e TICKETS \
  -v "$HERE/shoot.js:/work/shoot.js:ro,z" -v "$ROOT/out/screens:/out:z" -w /out/.npm "$IMG" \
  bash -c 'npm i --silent --no-fund --no-audit playwright@1.49.1 >/dev/null && cp /work/shoot.js . && node shoot.js'
ls "$ROOT/out/screens"/*.png
