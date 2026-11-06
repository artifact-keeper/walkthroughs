#!/usr/bin/env bash
# Web UI screenshots of the site stack (1920x1080, light theme) into out/demo/screens/. The
# browser runs on the stack's network and reaches https://ak.internal like every client; it
# logs in as admin (registry/.env). Run after make disconnect: the images show the site.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"; load_env
IMG=localhost/ak-offgrid/screens:latest
if ! podman image exists "$IMG"; then
  podman build --network host -q -t "$IMG" -f "$HERE/screens.Containerfile" "$HERE" >/dev/null
fi
mkdir -p "$ROOT/out/demo/screens"
PW="$ADMIN_PASSWORD" podman run --rm --network "$NET" -e PW \
  -v "$HERE/shoot.js:/opt/shoot/shoot.js:ro,z" -v "$ROOT/out/demo/screens:/out:z" -w /opt/shoot "$IMG" \
  node shoot.js
ls "$ROOT/out/demo/screens"/*.png
