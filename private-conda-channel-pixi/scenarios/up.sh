#!/usr/bin/env bash
# make scenarios-up: bring the scenario overlay up beside the ak-conda stack and configure it.
#   1. scn-fake-forge channel files (fake-forge.sh build)
#   2. compose project ak-scn-nexus: scn-nexus + scn-fake-forge (compose.nexus.yml)
#   3. Artifact Keeper scn-* repositories and the scn-reader token (ak-setup.sh)
#   4. Nexus configuration through its REST API (nexus/bootstrap.sh)
#   5. .work/conda-only: project/ without its PyPI dependency, locked (the outage scenarios
#      use it so that a PyPI failure, which goes to ak.internal directly, does not mask the conda result)
# Idempotent. Needs the ak-conda stack up (make registry-up).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $(backend_health) == healthy ]] || { echo "ak-conda-backend is not healthy; make registry-up first" >&2; exit 1; }
"$SCN_DIR/fake-forge.sh" build
[[ -n $(podman inspect scn-fake-forge --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null) ]] || podman rm -f scn-fake-forge >/dev/null 2>&1 || true
t0=$SECONDS
podman compose -p ak-scn-nexus -f "$SCN_DIR/compose.nexus.yml" up -d 2>&1 | grep -v '^$' | tail -3
wait_http "$NX/service/rest/v1/status/writable" 600 >/dev/null
log "scn-nexus writable after $((SECONDS - t0)) s"
"$SCN_DIR/ak-setup.sh"
"$SCN_DIR/nexus/bootstrap.sh"
if [[ ! -f "$WORK/conda-only/pixi.lock" ]]; then
  mkdir -p "$WORK/conda-only"; sed '/^\[pypi-options\]/,/^humanize/d' "$ROOT/project/pixi.toml" > "$WORK/conda-only/pixi.toml"
  cp "$ROOT/project/pixi.lock" "$WORK/conda-only/"
  CACHE_VOLUME=scn-up "$SCN_DIR/pixi-through.sh" nexus "$WORK/conda-only" lock >/dev/null 2>&1 || { echo "conda-only lock failed" >&2; exit 1; }
  log "locked .work/conda-only through Nexus"
fi
log "ready: Nexus $NX (admin password: SCN_NEXUS_ADMIN_PASSWORD in scenarios/.env), fake-forge http://scn-fake-forge:8000"
