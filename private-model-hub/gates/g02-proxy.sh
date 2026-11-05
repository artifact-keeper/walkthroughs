#!/usr/bin/env bash
# G2 Proxy: huggingface_hub, transformers and sentence-transformers through a Remote, the
# cache layout huggingface_hub builds, and cache hits on a second pull. The lab Hub checks
# always run; the huggingface.co checks need the backend to reach it (else BLOCKED(network)).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G2
pull_checks() { # REPO MODEL LABEL DIMS FILES [snapshot args]
  local repo=$1 model=$2 label=$3 dims=$4 nfiles=$5; shift 5
  local h1="g2-$repo-1-$RUNID" h2="g2-$repo-2-$RUNID" sha snap
  call developer GET "$HFAPI/$repo/api/models/$model/revision/main" >/dev/null; sha=$(jq -r .sha "$FOUT/.body")
  hf developer "$repo" -h "$h1" -- snapshot "$model" "$@" > "$GOUT/g2-$repo-snap.json"; jq -c '{ok, commit, files}' "$GOUT/g2-$repo-snap.json"
  check $G "$label: snapshot_download completes" "$(hfwhy "$GOUT/g2-$repo-snap.json")" ok "$GOUT/g2-$repo-snap.json"
  snap="$ROOT/out/homes/$h1/.cache/huggingface/hub/models--${model//\//--}"
  check $G "$label: the snapshot directory and refs/main are the upstream commit ($sha)" "refs/main $(cat "$snap/refs/main" 2>/dev/null)" \
    bash -c "[[ '$sha' =~ ^[0-9a-f]{40}\$ && \$(cat '$snap/refs/main') == '$sha' && -d '$snap/snapshots/$sha' ]]"
  hf developer "$repo" -h "$h1" -- encode "$model" > "$GOUT/g2-$repo-encode.json"; cat "$GOUT/g2-$repo-encode.json"
  check $G "$label: SentenceTransformer.encode on CPU gives $dims-dimension vectors" "$(hfwhy "$GOUT/g2-$repo-encode.json")" \
    jq -e ".ok and .shape == [2, $dims]" "$GOUT/g2-$repo-encode.json"
  local hits0; hits0=$(metric "$repo" hit)
  hf developer "$repo" -h "$h2" -- snapshot "$model" "$@" > "$GOUT/g2-$repo-snap2.json"
  local hits1; hits1=$(metric "$repo" hit)
  echo "ak_proxy_cache_lookups_total{repository=\"$repo\",result=\"hit\"} $hits0 -> $hits1"
  # The counter does not count every lookup (HEADs and small streamed files are left out; see
  # the findings), so this only asks that it rises; the upstream log check below is the strict one.
  check $G "$label: a second workstation's pull is served from the cache (ak_proxy_cache_lookups_total hits rise)" "$hits0 -> $hits1" \
    bash -c "jq -e .ok '$GOUT/g2-$repo-snap2.json' >/dev/null && (( $hits1 > $hits0 ))"
  if jq -e '.files | index("1_Pooling/config.json")' "$GOUT/g2-$repo-snap.json" >/dev/null; then
    pass $G "$label: snapshot_download fetches files in subdirectories (1_Pooling/config.json)"
  else
    blocked ak-fix $G "$label: snapshot_download fetches files in subdirectories (1_Pooling/config.json)" \
      "the tree listing drops ?recursive=true, so 1_Pooling/config.json is not listed (findings F2)"
  fi
}
since=$(date -u +%FT%TZ)
pull_checks hf-lab "$LAB_MODEL" "lab Hub" 32 9
# Files the model has: the library's probes for optional files it does not have (404s, cached
# for 45 s only) may go upstream again and are not counted.
lab_log "$since" | jq -c 'select(.path | contains("/resolve/")) | [.m, .path, .status]' | sort | uniq -c
n=$(lab_log "$since" | jq -r --arg m "/$LAB_MODEL/resolve/" 'select((.path | contains($m)) and .status != 404) | .path' | wc -l)
echo "lab Hub requests for files of $LAB_MODEL during G2: $n"
check $G "lab Hub: pulls of a model already in the cache fetch none of its files upstream" "$n requests" test "$n" -eq 0

if hub_reachable; then
  pull_checks hf-hub "$HUB_MODEL" "huggingface.co" 384 10 "${HUB_FILES[@]}"
else
  for c in "snapshot_download completes" "the snapshot directory and refs/main are the upstream commit" \
           "SentenceTransformer.encode on CPU gives 384-dimension vectors" "a second workstation's pull is served from the cache"; do
    blocked network $G "huggingface.co: $c" "the backend cannot reach huggingface.co"
  done
fi
