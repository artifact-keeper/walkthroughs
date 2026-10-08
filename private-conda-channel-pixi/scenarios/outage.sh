#!/usr/bin/env bash
# Outage drills through a scenario product (default nexus). Leaves everything as found.
#   backend   stop ak-conda-backend for OUTAGE_S (60) seconds with the registry's
#             compose helper, run the client checks, start it again, wait healthy
#   forge     point AK's conda-forge remote at an unreachable host, run the client
#             checks, restore the exact upstream_url (trap)
# Client checks (each with a cold client cache):
#   1. pixi install --locked, conda-only copy of project/ (.work/conda-only: project/
#      without its PyPI dependency, relocked through the product; made here if missing)
#   2. pixi install --locked, project/ as is (its PyPI package comes from ak.internal)
#   3. fresh solve (pixi lock, no lockfile) with the product's metadata cache as is
#   4. fresh solve after invalidating the product's metadata cache
#   5. a package the product has never cached
# Usage: scenarios/outage.sh backend|forge [nexus]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODE=$1 P=${2:-nexus}; U=$(AK_HOST_URL); OUTAGE_S=${OUTAGE_S:-60}
NXA="http://127.0.0.1:${NEXUS_PORT:-30481}/service/rest"; NXR="http://127.0.0.1:${NEXUS_PORT:-30481}/repository"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
invalidate() { curl -sS -u "admin:$SCN_NEXUS_ADMIN_PASSWORD" -X POST "$NXA/v1/repositories/$1/invalidate-cache" -o /dev/null -w "  invalidate $1: HTTP %{http_code}\n"; }
# solves use the conda-only manifest so a PyPI failure (ak.internal) does not mask the conda result
fresh_dir() { rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"; cp "$WORK/conda-only/pixi.toml" "$WORK/$1/"; }
checks() { # TAG
  local tag=$1 v
  for v in scn-o-1 scn-o-2 scn-o-3 scn-o-4; do podman volume rm -f "$v" >/dev/null 2>&1; done
  rm -rf "$WORK/conda-only/.pixi"
  CACHE_VOLUME=scn-o-1 "$SCN_DIR/measure.sh" "$P" "$tag-1-install-locked-conda-only" "$SCN_DIR/pixi-through.sh" "$P" "$WORK/conda-only" install --locked
  rm -rf "$WORK/full"; mkdir -p "$WORK/full"; cp "$ROOT/project/pixi.toml" "$ROOT/project/pixi.lock" "$WORK/full/"
  CACHE_VOLUME=scn-o-2 TAIL=6 "$SCN_DIR/measure.sh" "$P" "$tag-2-install-locked-project" "$SCN_DIR/pixi-through.sh" "$P" "$WORK/full" install --locked
  fresh_dir solve3; CACHE_VOLUME=scn-o-3 TAIL=6 "$SCN_DIR/measure.sh" "$P" "$tag-3-solve-cached-metadata" "$SCN_DIR/pixi-through.sh" "$P" "$WORK/solve3" lock
  invalidate ak-virtual; invalidate ak-internal
  fresh_dir solve4; CACHE_VOLUME=scn-o-4 TAIL=8 "$SCN_DIR/measure.sh" "$P" "$tag-4-solve-invalidated-metadata" "$SCN_DIR/pixi-through.sh" "$P" "$WORK/solve4" lock
  curl -sS -o "$WORK/runs/$tag-5.body" -w "== $tag-5 never-cached package via $P: HTTP %{http_code}, %{time_total}s\n" "$NXR/ak-virtual/noarch/${NEVER:-toolz-1.2.0-pyh5ded981_0.conda}"
}
if [[ ! -f "$WORK/conda-only/pixi.lock" ]]; then
  mkdir -p "$WORK/conda-only"; sed '/^\[pypi-options\]/,/^humanize/d' "$ROOT/project/pixi.toml" > "$WORK/conda-only/pixi.toml"
  cp "$ROOT/project/pixi.lock" "$WORK/conda-only/"
  CACHE_VOLUME=scn-o-warm "$SCN_DIR/pixi-through.sh" "$P" "$WORK/conda-only" lock >/dev/null 2>&1 || { echo "conda-only lock failed" >&2; exit 1; }
fi
case "$MODE" in
backend)
  echo "== warm-up: product metadata and packages"
  fresh_dir warm; CACHE_VOLUME=scn-o-warm "$SCN_DIR/pixi-through.sh" "$P" "$WORK/warm" lock >/dev/null 2>&1 && echo "  warm solve ok"
  CACHE_VOLUME=scn-o-warm "$SCN_DIR/pixi-through.sh" "$P" "$WORK/conda-only" install --locked >/dev/null 2>&1 && echo "  warm install ok"
  trap 'compose start backend >/dev/null 2>&1' EXIT
  t_stop=$SECONDS; compose stop backend 2>&1 | tail -1; echo "== ak-conda-backend stopped at $(date -u +%T)"
  akcurl -sS -o /dev/null -w "  direct AK during outage: HTTP %{http_code}\n" -H "Authorization: Bearer $(consumer_token)" "$U/conda/conda-virtual/noarch/repodata.json"
  checks backend-down
  left=$(( OUTAGE_S - (SECONDS - t_stop) )); (( left > 0 )) && sleep "$left"
  compose start backend 2>&1 | tail -1; echo "== ak-conda-backend started after $((SECONDS - t_stop)) s"
  for _ in $(seq 90); do [[ $(podman inspect ak-conda-backend --format '{{.State.Health.Status}}') == healthy ]] && break; sleep 2; done
  echo "  backend health: $(podman inspect ak-conda-backend --format '{{.State.Health.Status}}'); repodata via AK: $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(consumer_token)" "$U/conda/conda-virtual/noarch/repodata.json")"
  ;;
forge)
  orig=$(akcurl -fsS -H "Authorization: Bearer $(admin_token)" "$U/api/v1/repositories/conda-forge" | jq -r .upstream_url)
  echo "== AK conda-forge upstream_url: $orig"
  setu() { akcurl -sS -o /dev/null -w "  PATCH upstream_url=$1: HTTP %{http_code}\n" -X PATCH -H "Authorization: Bearer $(admin_token)" \
           -H 'Content-Type: application/json' -d "$(jq -nc --arg u "$1" '{upstream_url:$u}')" "$U/api/v1/repositories/conda-forge"; }
  trap 'setu "$orig"' EXIT
  setu "${BLACKHOLE:-https://conda-forge.invalid/conda-forge}"
  akcurl -sS -o /dev/null -w "  direct AK virtual during block: HTTP %{http_code}\n" -H "Authorization: Bearer $(consumer_token)" "$U/conda/conda-virtual/noarch/repodata.json"
  akcurl -sS -o /dev/null -w "  direct AK virtual, never-cached package: HTTP %{http_code}\n" -H "Authorization: Bearer $(consumer_token)" "$U/conda/conda-virtual/noarch/${NEVER:-toolz-1.2.0-pyh5ded981_0.conda}"
  checks forge-blocked
  setu "$orig"; trap - EXIT
  now=$(akcurl -fsS -H "Authorization: Bearer $(admin_token)" "$U/api/v1/repositories/conda-forge" | jq -r .upstream_url)
  [[ "$now" == "$orig" ]] && echo "== restored upstream_url: $now" || echo "!! upstream_url is $now, expected $orig"
  ;;
*) echo "usage: $0 backend|forge [nexus]" >&2; exit 2 ;;
esac
