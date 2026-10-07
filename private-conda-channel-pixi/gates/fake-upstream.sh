#!/usr/bin/env bash
# A "public" conda channel we control, standing in for a compromised or
# squatted upstream: acme-core 99.0.0 (same name as our internal package).
# Built with rattler-build, indexed with rattler-index, served by a static HTTP
# server in container ak-conda-fake-upstream (alias fake-upstream on ak-conda-net).
# Usage: gates/fake-upstream.sh up|down
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CH="$ROOT/out/fake-upstream"
case "${1:-up}" in
  down) podman rm -f ak-conda-fake-upstream >/dev/null 2>&1 || true; exit 0 ;;
esac
ls "$CH"/noarch/acme-core-99.0.0-*.conda >/dev/null 2>&1 || \
  OUT_DIR="$CH" ACME_CORE_VERSION=99.0.0 "$ROOT/packages/build.sh" acme-core >/dev/null
rm -rf "$CH/bld" "$CH/src_cache"
podman run --rm --network "$NET" -v ak-conda-pixi-cache:/cache -v "$CH:/chan:z" \
  -v "$TOKENS/consumer-auth.json:/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json \
  "$CLIENT" pixi exec -s rattler-index -- rattler-index fs /chan 2>&1 | grep -v '^ WARN' || true
mkdir -p "$CH/linux-64"; [[ -f "$CH/linux-64/repodata.json" ]] || echo '{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{},"repodata_version":1}' > "$CH/linux-64/repodata.json"
podman rm -f ak-conda-fake-upstream >/dev/null 2>&1 || true
podman run -d --name ak-conda-fake-upstream --network "$NET" --ip 172.31.40.200 --network-alias fake-upstream \
  -v ak-conda-pixi-cache:/cache -v "$CH:/chan:ro,z" -v "$TOKENS/consumer-auth.json:/run/secrets/a.json:ro,z" \
  -e RATTLER_AUTH_FILE=/run/secrets/a.json -w /chan "$CLIENT" \
  pixi exec -s python -- python -m http.server 8000 >/dev/null
for _ in $(seq 30); do
  podman run --rm --network "$NET" "$CLIENT" bash -c 'timeout 2 bash -c "</dev/tcp/fake-upstream/8000"' 2>/dev/null && break; sleep 2; done
echo "fake upstream: http://fake-upstream:8000 ($(ls "$CH"/noarch/*.conda | xargs -n1 basename | tr '\n' ' '))"
