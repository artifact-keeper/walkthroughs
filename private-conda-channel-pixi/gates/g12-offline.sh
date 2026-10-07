#!/usr/bin/env bash
# G12 Offline and portable:
#   - `pixi install --frozen --offline` from a pre-filled cache succeeds with no network;
#   - the same lock installs from a different mirror (a plain directory served
#     over HTTP), proving the lock is portable across mirrors;
#   - a package with one flipped byte on that mirror fails pixi's sha256 check.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G12; PROJECT="${PROJECT:-project-direct}"; VOL=ak-conda-g12-cache
podman volume rm -f "$VOL" >/dev/null 2>&1
rm -rf "$ROOT/$PROJECT/.pixi/envs"
CACHE_VOLUME=$VOL "$ROOT/$PROJECT/pixi-run.sh" install --locked >/dev/null 2>&1   # fill the cache
rm -rf "$ROOT/$PROJECT/.pixi/envs"
out=$(NETWORK=none CACHE_VOLUME=$VOL "$ROOT/$PROJECT/pixi-run.sh" install --frozen --offline 2>&1 | grep -v '^ WARN'); echo "$out" | tail -2
grep -q 'has been installed' <<<"$out" && pass $G "pixi install --frozen --offline with --network none from a pre-filled cache" \
  || fail $G "offline install" "$(tail -1 <<<"$out")"
out=$(NETWORK=none CACHE_VOLUME=$VOL "$ROOT/$PROJECT/pixi-run.sh" run --frozen --offline hypot 2>&1 | tail -1); echo "offline run: $out"

# a second mirror: the internal channel's files as a static directory
M="$ROOT/out/g12-mirror"; rm -rf "$M"; mkdir -p "$M/good" "$M/bad"
for sub in noarch linux-64; do mkdir -p "$M/good/$sub" "$M/bad/$sub"; cp "$ROOT"/packages/out/$sub/*.conda "$M/good/$sub/"; cp "$ROOT"/packages/out/$sub/*.conda "$M/bad/$sub/"; done
python3 - "$M/bad/noarch/$(ls "$M/bad/noarch" | grep -m1 acme-core-1.0.0)" <<'PY'
import sys; p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[len(b)//2]^=0x01; open(p,'wb').write(b)
PY
podman rm -f ak-conda-g12-mirror >/dev/null 2>&1
podman run -d --name ak-conda-g12-mirror --network "$NET" --network-alias mirror2 -v ak-conda-pixi-cache:/cache -v "$M:/m:ro,z" \
  -v "$TOKENS/consumer-auth.json:/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json -w /m "$CLIENT" \
  pixi exec -s python -- python -m http.server 8000 >/dev/null; sleep 6
mirror_install() { # good|bad
  mkdir -p "$SP_TMP/g12"; cp "$ROOT/client/.work/pixi-config.toml" "$SP_TMP/g12/config.toml"
  sed -i "/^\[mirrors\]/a \"https://ak.internal/conda/conda-internal\" = [\"http://mirror2:8000/$1\"]" "$SP_TMP/g12/config.toml"
  podman volume rm -f ak-conda-g12-m >/dev/null 2>&1; rm -rf "$ROOT/$PROJECT/.pixi/envs"
  NETWORK=$NET CACHE_VOLUME=ak-conda-g12-m EXTRA_PODMAN_ARGS="-v $SP_TMP/g12/config.toml:/etc/pixi/config.toml:ro,z" \
    "$ROOT/$PROJECT/pixi-run.sh" install --locked 2>&1 | grep -v '^ WARN'
}
out=$(mirror_install good); echo "$out" | tail -1
echo "requests served by mirror2/good: $(podman logs ak-conda-g12-mirror 2>&1 | grep -c 'GET /good/')"
grep -q 'has been installed' <<<"$out" && pass $G "the same pixi.lock installs from a different mirror of the internal channel (mirrors config only)" \
  || fail $G "install from a second mirror" "$(tail -2 <<<"$out")"
out=$(mirror_install bad); echo "$out" | tail -4
if ! grep -q 'has been installed' <<<"$out" && grep -qiE 'sha256|hash|mismatch' <<<"$out"; then
  pass $G "a flipped byte on the mirror fails pixi's sha256 check: $(tr -s ' \n│╰─▶├×' ' ' <<<"$out" | grep -oiE '[^.]*(sha256|hash)[^.]*' | head -1 | cut -c1-160)"
else fail $G "flipped byte detected" "$(tail -2 <<<"$out")"; fi
podman rm -f ak-conda-g12-mirror >/dev/null 2>&1; podman volume rm -f ak-conda-g12-m "$VOL" >/dev/null 2>&1
