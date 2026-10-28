#!/usr/bin/env bash
# Build localhost/ak-agent/sandbox:1 with base images pulled through the registry
# (builder token, registry/.tokens/builder-podman.json) and the internal CA baked in.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
load_env
P="localhost:${HTTPS_PORT}"
cp "$CA" "$here/ak-internal-ca.crt"
podman build -q --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/builder-podman.json" \
  --build-arg REG="$P" --label ak-agent=sandbox -t localhost/ak-agent/sandbox:1 "$here" >/dev/null
rm -f "$here/ak-internal-ca.crt"
podman run --rm localhost/ak-agent/sandbox:1 sh -c 'echo "sandbox: uv $(uv --version | cut -d" " -f2), node $(node --version), npm $(npm --version), python $(python3 --version | cut -d" " -f2)"'
