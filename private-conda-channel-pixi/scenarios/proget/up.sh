#!/usr/bin/env bash
# make scenarios-up-proget: ProGet Free (compose project ak-scn-proget) on ak-conda-net beside
# the ak-conda stack, configured for the AM=proget scenarios.
#   1. .work/proget-ca-bundle.crt: the image's system bundle plus the ak.internal CA
#      (mounted over /etc/ssl/certs/ca-certificates.crt; ProGet uses the OpenSSL bundle)
#   2. compose up, wait for the UI (/health stays 500 "Product license is not valid" until
#      a licence key is entered once in the UI; the key lives in the scn-proget-database volume)
#   3. scn-fake-forge (fake-forge.sh up), the AK scn-* repositories and token (ak-setup.sh)
#   4. proget/bootstrap.sh: API key, lock-down, connectors and feeds
#   5. .work/conda-only (shared with the Nexus scenarios), locked straight against AK
# Idempotent. Needs the ak-conda stack up (make registry-up).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
[[ $(backend_health) == healthy ]] || { echo "ak-conda-backend is not healthy; make registry-up first" >&2; exit 1; }
img=proget.inedo.com/productimages/inedo/proget:${PROGET_VERSION:-26.0.12}
{ podman run --rm --entrypoint cat "$img" /etc/ssl/certs/ca-certificates.crt; cat "$CA"; } > "$WORK/proget-ca-bundle.crt"
t0=$SECONDS
podman compose -p ak-scn-proget -f "$SCN_DIR/compose.proget.yml" up -d 2>&1 | grep -v '^$' | tail -2
until [[ $(curl -sS -o /dev/null -w '%{http_code}' "$PG/" 2>/dev/null) =~ ^(200|302)$ ]]; do (( SECONDS - t0 > 600 )) && { echo "scn-proget did not answer" >&2; exit 1; }; sleep 2; done
log "scn-proget answers after $((SECONDS - t0)) s (compose up included); /health HTTP $(curl -sS -o /dev/null -w '%{http_code}' "$PG/health")"
"$SCN_DIR/fake-forge.sh" build   # files only; the container (compose project ak-scn-nexus) is started if absent
[[ $(podman inspect scn-fake-forge --format "{{.State.Running}}" 2>/dev/null) == true ]] || "$SCN_DIR/fake-forge.sh" up
"$SCN_DIR/ak-setup.sh"
"$SCN_DIR/proget/bootstrap.sh"
if [[ ! -f "$WORK/conda-only/pixi.lock" ]]; then
  mkdir -p "$WORK/conda-only"; sed '/^\[pypi-options\]/,/^humanize/d' "$ROOT/project/pixi.toml" > "$WORK/conda-only/pixi.toml"
  cp "$ROOT/project/pixi.lock" "$WORK/conda-only/"
  podman run --rm --network "$NET" -v scn-up:/cache -v "$WORK/conda-only:/work:z" -w /work \
    -v "$TOKENS/consumer-auth.json:/run/secrets/rattler-auth.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
    "$CLIENT" pixi lock >/dev/null 2>&1 || { echo "conda-only lock failed" >&2; exit 1; }
  log "locked .work/conda-only straight against AK"
fi
log "ready: ProGet $PG (Admin password: PROGET_ADMIN_PASSWORD in scenarios/.env), feeds http://scn-proget/conda/{ak-virtual,ak-internal,ak-scn-virtual,scn-fake,cf-direct,merged,merged-fake}"
