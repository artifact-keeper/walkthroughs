#!/usr/bin/env bash
# G3 Resolve: `pixi install --locked` on a network with no internet
# (build-isolated, internal: true) succeeds through the registry; the lock records
# canonical conda-forge URLs while every request goes to ak.internal; the registry
# records the downloads.
# Runs for project/ (one virtual channel) and project-direct/ (internal + conda-forge mirror).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G3
# 0. the network really is isolated
probe() { # network -> lines: dns-conda dns-pypi tcp-1.1.1.1 tcp-ak
  podman run --rm --network "$1" "$CLIENT" bash -c '
    getent hosts conda.anaconda.org >/dev/null && echo dns-conda=ok || echo dns-conda=none
    getent hosts pypi.org >/dev/null && echo dns-pypi=ok || echo dns-pypi=none
    timeout 5 bash -c "</dev/tcp/1.1.1.1/443" 2>/dev/null && echo tcp-1.1.1.1=ok || echo tcp-1.1.1.1=none
    timeout 5 bash -c "</dev/tcp/ak.internal/443" 2>/dev/null && echo tcp-ak.internal=ok || echo tcp-ak.internal=none' 2>&1 | tr '\n' ' '; }
iso=$(probe "$ISOLATED_NET"); open=$(probe "$NET")
echo "build-isolated: $iso"; echo "ak-conda-net:   $open"
if [[ "$iso" == "dns-conda=none dns-pypi=none tcp-1.1.1.1=none tcp-ak.internal=ok " ]]; then
  pass $G "build-isolated reaches ak.internal:443 and nothing else (no DNS for conda.anaconda.org/pypi.org, no route to 1.1.1.1)"
else fail $G "build-isolated isolation" "$iso"; fi

for proj in project-direct project; do
  [[ -f "$ROOT/$proj/pixi.lock" ]] || { 
    if [[ $proj == project ]]; then
      out=$("$ROOT/$proj/pixi-run.sh" lock 2>&1 | grep -v '^ WARN'); echo "$out" | tail -5
      if [[ -f "$ROOT/$proj/pixi.lock" ]]; then echo "locked $proj"; else
        blocked F2,F3 $G "$proj (virtual channel) locks" "$(tr -s ' \n│╰─▶├×' ' ' <<<"$out" | grep -oE 'No candidates were found for [^.]*' | head -1) (virtual repodata omits the conda-forge member)"
        continue; fi
    fi; }
  vol="ak-conda-g3-cache-$proj"; podman volume rm -f "$vol" >/dev/null 2>&1
  rm -rf "$ROOT/$proj/.pixi/envs"
  n0=$(akcurl -fsS -H "$(admin_h)" "$U/api/v1/admin/downloads?per_page=1" | jq .total)
  t0=$(date +%s); s0=$SECONDS
  out=$(NETWORK="$ISOLATED_NET" CACHE_VOLUME="$vol" "$ROOT/$proj/pixi-run.sh" install --locked 2>&1 | grep -v '^ WARN'); rc=$?
  dt=$((SECONDS - s0)); echo "$out" | tail -3
  n1=$(akcurl -fsS -H "$(admin_h)" "$U/api/v1/admin/downloads?per_page=1" | jq .total)
  access_since "$t0" > "$SP_TMP/g3-$proj.tsv"
  pkgs=$(grep -cE '\.(conda|tar\.bz2|whl)\s' "$SP_TMP/g3-$proj.tsv")
  echo "requests to ak.internal: $(wc -l < "$SP_TMP/g3-$proj.tsv") (package downloads $pkgs); registry download records +$((n1 - n0)); $dt s cold"
  awk -F'\t' '{split($2,a,"/"); print a[2]"/"a[3]}' "$SP_TMP/g3-$proj.tsv" | sort | uniq -c
  lockurls=$(grep -oE '^- (conda|pypi): https://[^/]+' "$ROOT/$proj/pixi.lock" | sort | uniq -c)
  echo "pixi.lock package URL hosts:"; echo "$lockurls"
  if grep -q 'environment has been installed' <<<"$out"; then
    pass $G "$proj: pixi install --locked on build-isolated, cold cache ($dt s, $pkgs package downloads, all via ak.internal)"
  else fail $G "$proj: pixi install --locked on build-isolated" "$(tail -2 <<<"$out")"; fi
  if (( n1 - n0 >= pkgs && pkgs > 0 )); then pass $G "$proj: registry recorded a download for every package fetched (+$((n1 - n0)))"
  else fail $G "$proj: registry download records (audit of pulls)" "+$((n1 - n0)) records for $pkgs package downloads: hosted downloads are recorded, proxy (conda-forge, PyPI) downloads are not"; fi
  podman volume rm -f "$vol" >/dev/null 2>&1
done
