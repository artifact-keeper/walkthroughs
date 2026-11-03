#!/usr/bin/env bash
# Take the UI screenshots with Playwright in a container on the registry network (the
# container resolves ak.internal through the compose network alias). Output: screens/out/.
# The admin password comes from registry/.env; it never leaves the host.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"; load_env
: "${IMG_PLAYWRIGHT:=mcr.microsoft.com/playwright/python:v1.52.0-noble}"
mkdir -p "$here/out"
podman run --rm --network "$NET" -e AK_PASSWORD="$ADMIN_PASSWORD" -e AK_URL="$AK_URL" -e OUT=/out \
  -v "$here/shoot.py:/shoot.py:ro,z" -v "$here/out:/out:z" "$IMG_PLAYWRIGHT" \
  sh -c 'pip install -q playwright==1.52.0 && python3 /shoot.py'
# The image ships the browsers under /ms-playwright but not the Python package itself (as of
# v1.52.0-noble), hence the pip install; it matches the browser build in the image.
ls -la "$here/out"
