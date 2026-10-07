#!/usr/bin/env bash
# Build localhost/ak-conda/pixi-client:${CLIENT_TAG:-0.81.0} (base image pulled through the registry).
# client/.work/ holds the configs of the LAST build; image/build.sh copies them.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
cp "$CA" "$HERE/ak-internal-ca.crt"
# CLIENT_SHARDS=on: drop the disable-sharded workaround block (fixed backend).
mkdir -p "$HERE/.work"
for f in pixi-config.toml rattler-config.toml; do
  if [[ "${CLIENT_SHARDS:-off}" == on ]]; then sed '/^# WORKAROUND/,$d' "$HERE/$f" > "$HERE/.work/$f"
  else cp "$HERE/$f" "$HERE/.work/$f"; fi
done
podman build --cert-dir "$OUT/certs.d/localhost:30444" --authfile "$TOKENS/consumer-podman.json" \
  --network none -t "localhost/ak-conda/pixi-client:${CLIENT_TAG:-0.81.0}" "$HERE"
rm -f "$HERE/ak-internal-ca.crt"
echo "client: shards ${CLIENT_SHARDS:-off}"
