#!/usr/bin/env bash
# Take the web UI screenshots used in the docs, into out/screens/ (optional; not part of
# make all). Runs Playwright's image on ak-hf-net, so the browser reaches https://ak.internal
# like every other client. The admin password comes from registry/.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
IMG=mcr.microsoft.com/playwright:v1.49.1-noble
PAGES='[["/repositories","u01-repositories"],["/repositories/hf-local","u02-hf-local"],
        ["/repositories/hf-staging","u03-hf-staging"],["/repositories/hf-curated","u04-hf-curated"],
        ["/packages?format=huggingface","u05-packages"]]'
export PAGES
mkdir -p "$ROOT/out/screens" "$ROOT/out/screens/.npm"
PW="$ADMIN_PASSWORD" podman run --rm --network "$NET" -e PW -e PAGES \
  -v "$HERE/shoot.js:/work/shoot.js:ro,z" -v "$ROOT/out/screens:/out:z" -w /out/.npm "$IMG" \
  bash -c 'npm i --silent --no-fund --no-audit playwright@1.49.1 >/dev/null && cp /work/shoot.js . && node shoot.js'
ls "$ROOT/out/screens"/*.png
