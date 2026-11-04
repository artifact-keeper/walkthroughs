#!/usr/bin/env bash
# Take the web UI screenshots used in the docs, into out/screens/ (optional; not part of
# make all). Runs Playwright's image on ak-agents-net, so the browser reaches
# https://ak.internal like every other client. The admin password comes from registry/.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
IMG=mcr.microsoft.com/playwright:v1.49.1-noble
mkdir -p "$ROOT/out/screens" "$ROOT/out/screens/.npm"
PW="$ADMIN_PASSWORD" podman run --rm --network "$NET" -e PW \
  -v "$HERE/shoot.js:/work/shoot.js:ro,z" -v "$ROOT/out/screens:/out:z" -w /out/.npm "$IMG" \
  bash -c 'npm i --silent --no-fund --no-audit playwright@1.49.1 >/dev/null && cp /work/shoot.js . && node shoot.js'
ls "$ROOT/out/screens"/*.png
