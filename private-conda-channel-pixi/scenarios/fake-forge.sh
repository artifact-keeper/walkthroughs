#!/usr/bin/env bash
# A tiny "public" conda channel we control, for the merge-precedence test:
# http://scn-fake-forge:8000 on ak-conda-net (container scn-fake-forge).
#   noarch/acme-core-99.0.0-pyh4616a5c_0.conda   the squatted name, higher version
#   noarch/acme-core-1.0.0-pyh4616a5c_0.conda    SAME file name as conda-internal's
#       acme-core 1.0.0, different bytes (a copy of the 99.0.0 file), recorded in
#       repodata with its own sha256 and the marker "scn_fake": true
# Built from the gate's fake upstream (out/fake-upstream; gates/fake-upstream.sh
# builds it). linux-64 has an empty repodata. Plain repodata.json only (no .zst,
# no shards) plus channeldata.json, like most simple channels.
# Usage: scenarios/fake-forge.sh build|up|down
#   build  write the channel files only
#   up     build, then start the fake-forge service of compose.nexus.yml
#   down   remove the container
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CH="$WORK/fake-forge"
case "${1:-up}" in down) podman rm -f scn-fake-forge >/dev/null 2>&1 || true; exit 0 ;; build|up) ;; *) echo "usage: $0 build|up|down" >&2; exit 2 ;; esac
SRC="$ROOT/out/fake-upstream/noarch"
ls "$SRC"/acme-core-99.0.0-*.conda >/dev/null 2>&1 || "$ROOT/gates/fake-upstream.sh" up
# empty in place: the running container bind-mounts this directory
mkdir -p "$CH"; rm -rf "${CH:?}"/*; mkdir -p "$CH/noarch" "$CH/linux-64"
f99=$(basename "$SRC"/acme-core-99.0.0-*.conda); f10=acme-core-1.0.0-pyh4616a5c_0.conda
cp "$SRC/$f99" "$CH/noarch/$f99"; cp "$SRC/$f99" "$CH/noarch/$f10"
jq --arg f99 "$f99" --arg f10 "$f10" '
  .["packages.conda"] = {($f99): .["packages.conda"][$f99],
                         ($f10): (.["packages.conda"][$f99] + {version: "1.0.0", scn_fake: true})}
  | .packages = {}' "$SRC/repodata.json" > "$CH/noarch/repodata.json"
echo '{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{},"repodata_version":1}' > "$CH/linux-64/repodata.json"
# channeldata.json: ProGet's conda connector reads it first (the subdir list) and fails the
# whole feed with "The remote server returned an error: (404) Not Found." without it.
jq -n '{channeldata_version: 1, subdirs: ["linux-64", "noarch"],
        packages: {"acme-core": {subdirs: ["noarch"], version: "99.0.0"}}}' > "$CH/channeldata.json"
[[ ${1:-up} == build ]] && { log "channel files in $CH"; exit 0; }
# a container from before the compose service existed (podman run) is replaced
[[ -n $(podman inspect scn-fake-forge --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null) ]] || podman rm -f scn-fake-forge >/dev/null 2>&1 || true
podman compose -p ak-scn-nexus -f "$SCN_DIR/compose.nexus.yml" up -d fake-forge >/dev/null 2>&1
for _ in $(seq 30); do
  podman run --rm --network "$NET" docker.io/library/busybox:1.37 wget -q -O /dev/null http://scn-fake-forge:8000/noarch/repodata.json 2>/dev/null && break; sleep 2; done
log "http://scn-fake-forge:8000 serves noarch/{$f99,$f10}"
