#!/usr/bin/env bash
# G7 Offline: the Hub Remotes are frozen; with the lab Hub stopped and huggingface.co out of
# reach (flows/lib.sh disconnect), a workstation on ak-hf-offline (no route out) gets every
# seeded model from Artifact Keeper. Reconnects on exit.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G7
for r in hf-lab hf-hub; do
  t=$(call admin GET "/api/v1/repositories/$r/cache-ttl" | jq -r .cache_ttl_seconds)
  k=$(call admin GET "/api/v1/repositories/$r/on-upstream-not-found" | jq -r .on_upstream_not_found)
  check $G "$r is frozen: cache-ttl 315360000, on-upstream-not-found keep" "cache-ttl $t, $k" \
    bash -c "[[ '$t' == 315360000 && '$k' == keep ]]"
done
targets=("hf-lab $LAB_MODEL 9")
hub_ok=0; hub_reachable && hub_ok=1 && targets+=("hf-hub $HUB_MODEL 10")
declare -A SHA
for t in "${targets[@]}"; do
  read -r repo model _ <<<"$t"
  SHA[$repo]=$(call developer GET "$HFAPI/$repo/api/models/$model/revision/main" | jq -r .sha)
done

trap reconnect EXIT
disconnect
"$RUN" -o -- python -c '
import socket, sys
bad = []
for host in ("huggingface.co", "cas-bridge.xethub.hf.co", "pypi.org", "1.1.1.1"):
    try:
        socket.create_connection((host, 443), timeout=5).close(); bad.append(host)
    except OSError as e:
        print(host, "unreachable:", type(e).__name__)
sys.exit(1 if bad else 0)'
check $G "the offline workstation has no route out (huggingface.co, its CDN, pypi.org, 1.1.1.1)" "a host answered" test $? -eq 0

for t in "${targets[@]}"; do
  read -r repo model nfiles <<<"$t"
  sha=${SHA[$repo]} h="g7-$repo-$RUNID" L="$repo"
  args=(); [[ $repo == hf-hub ]] && args=("${HUB_FILES[@]}")
  hf developer "$repo" -o -h "$h" -- --timeout 120 snapshot "$model" "${args[@]}" > "$GOUT/g7-$repo-snap.json"
  jq -c '{ok, commit, n: (.files | length), seconds}' "$GOUT/g7-$repo-snap.json"
  check $G "$L: snapshot_download of the seeded model completes offline ($nfiles files, commit ${sha:0:12})" "$(hfwhy "$GOUT/g7-$repo-snap.json")" \
    jq -e --arg s "$sha" ".ok and .commit == \$s and (.files | length) == $nfiles" "$GOUT/g7-$repo-snap.json"
  call developer HEAD "$HFAPI/$repo/$model/resolve/$sha/config.json" >/dev/null
  check $G "$L: a seeded file is served fresh, not stale (200, no X-AK-Stale-Since)" "HTTP $(code) stale=$(hdr X-AK-Stale-Since)" \
    bash -c "[[ \$(cat '$FOUT/.code') == 200 ]] && ! grep -qi '^x-ak-stale-since' '$FOUT/.headers'"
  # snapshot_download leaves out files in subdirectories (G2); fetch the one the model needs
  # at the same commit, then load with HF_HUB_OFFLINE=1 from what Artifact Keeper served.
  hf developer "$repo" -o -h "$h" -- --timeout 120 download "$model" 1_Pooling/config.json --revision "$sha" > "$GOUT/g7-$repo-pool.json"
  export HF_HUB_OFFLINE=1
  hf developer "$repo" -o -h "$h" -e HF_HUB_OFFLINE -- --timeout 120 encode "$model" > "$GOUT/g7-$repo-enc.json"
  hf developer "$repo" -o -h "$h" -e HF_HUB_OFFLINE -- --timeout 120 automodel "$model" > "$GOUT/g7-$repo-auto.json"
  unset HF_HUB_OFFLINE
  jq -c '{cmd, ok, seconds}' "$GOUT/g7-$repo-pool.json" "$GOUT/g7-$repo-enc.json" "$GOUT/g7-$repo-auto.json"
  check $G "$L: the workstation loads it offline (SentenceTransformer and AutoModel, HF_HUB_OFFLINE=1)" "$(hfwhy "$GOUT/g7-$repo-enc.json") $(hfwhy "$GOUT/g7-$repo-auto.json")" \
    bash -c "jq -e .ok '$GOUT/g7-$repo-pool.json' >/dev/null && jq -e .ok '$GOUT/g7-$repo-enc.json' >/dev/null && jq -e .ok '$GOUT/g7-$repo-auto.json' >/dev/null"
  hf developer "$repo" -o -h "g7-$repo-direct-$RUNID" -- --timeout 60 encode "$model" > "$GOUT/g7-$repo-direct.json"
  jq -c '{ok, error, seconds}' "$GOUT/g7-$repo-direct.json"
  if ok "$GOUT/g7-$repo-direct.json"; then
    pass $G "$L: a fresh offline workstation loads the model straight from Artifact Keeper within 60 s"
  else
    blocked ak-fix $G "$L: a fresh offline workstation loads the model straight from Artifact Keeper within 60 s" \
      "each optional file the library probes is a 502 after a failed upstream attempt, and huggingface_hub retries 5xx (findings F3, artifact-keeper#5282)"
  fi
done
(( hub_ok )) || for c in "snapshot_download of the seeded model completes offline" "the workstation loads it offline"; do
  blocked network $G "huggingface.co: $c" "the backend cannot reach huggingface.co, so nothing was seeded from it"
done

s=$(date +%s%N)
call developer GET "$HFAPI/hf-lab/acme-lab/never-seeded/resolve/main/config.json" >/dev/null
ms=$(( ($(date +%s%N) - s) / 1000000 ))
echo "unseeded file: HTTP $(code) after $ms ms"
check $G "an unseeded file is not served offline, and the answer comes in under 10 s" "HTTP $(code) after $ms ms" \
  bash -c "[[ \$(cat '$FOUT/.code') =~ ^(404|502|503|504)\$ ]] && (( $ms < 10000 ))"
if [[ $(code) == 404 ]]; then
  pass $G "an unseeded file answers 404 (a clean miss), so clients do not retry"
else
  blocked ak-fix $G "an unseeded file answers 404 (a clean miss), so clients do not retry" \
    "it answers $(code) after trying the upstream; there is no cache-only mode (artifact-keeper#5282)"
fi
