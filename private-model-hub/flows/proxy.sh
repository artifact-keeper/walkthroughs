#!/usr/bin/env bash
# Step 2: proxy the Hub. The developer's workstation points HF_ENDPOINT at hf-lab (the lab
# Hub) and at hf-hub (huggingface.co), downloads with hf, hf_hub_download and
# snapshot_download, runs SentenceTransformer.encode on CPU, and a second workstation pulls
# the same model from the cache. hf-hub needs huggingface.co; without it that half is skipped
# (and gate G2 reports it BLOCKED(network)).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pull() { # REPO MODEL HOME [snapshot args...]
  local repo=$1 model=$2 home=$3; shift 3
  hf developer "$repo" -h "$home" -- snapshot "$model" "$@" | tee "$FOUT/proxy-$home-snapshot.json" | jq -c '{ok, commit, files}'
  hf developer "$repo" -h "$home" -- encode "$model" | tee "$FOUT/proxy-$home-encode.json"
  local c="$ROOT/out/homes/$home/.cache/huggingface/hub/models--${model//\//--}"
  echo "cache: $(cat "$c/refs/main") <- refs/main"
  (cd "$c/snapshots" && find . -mindepth 1 | sort | sed 's|^\./|  snapshots/|')
}

say "hf-lab: the developer pulls $LAB_MODEL (empty cache)"
upstream=$(lab_log | wc -l)
pull hf-lab "$LAB_MODEL" dev-lab
echo "upstream: the lab Hub logged $(( $(lab_log | wc -l) - upstream )) requests for this pull"
show developer GET "$HFAPI/hf-lab/api/models/$LAB_MODEL/revision/main" >/dev/null
echo "model info sha via hf-lab: $(jq -r .sha "$FOUT/.body")"

say "hf-lab: hf download (the CLI), into a fresh cache"
"$RUN" -r hf-lab -t developer -h dev-lab-cli -- hf download "$LAB_MODEL" 2>&1 | tail -1

say "hf-lab: a second workstation pulls the same model; Artifact Keeper serves it from its cache"
hits0=$(metric hf-lab hit); upstream=$(lab_log | wc -l)
pull hf-lab "$LAB_MODEL" dev-lab-2
echo "ak_proxy_cache_lookups_total{repository=\"hf-lab\",result=\"hit\"}: $hits0 -> $(metric hf-lab hit)"
echo "upstream: the lab Hub logged $(( $(lab_log | wc -l) - upstream )) requests for the second pull"

say "hf-hub: huggingface.co through Artifact Keeper"
if ! hub_reachable; then
  echo "huggingface.co is not reachable from the backend; skipping (gate G2 reports BLOCKED(network))"
  exit 0
fi
pull hf-hub "$HUB_MODEL" dev-hub "${HUB_FILES[@]}"
show developer GET "$HFAPI/hf-hub/api/models/$HUB_MODEL/revision/main" >/dev/null
echo "model info sha via hf-hub: $(jq -r .sha "$FOUT/.body")"
"$RUN" -r hf-hub -t developer -h dev-hub-cli -- hf download "$HUB_MODEL" config.json modules.json 2>&1 | tail -1
hits0=$(metric hf-hub hit)
pull hf-hub "$HUB_MODEL" dev-hub-2 "${HUB_FILES[@]}" >/dev/null
echo "ak_proxy_cache_lookups_total{repository=\"hf-hub\",result=\"hit\"}: $hits0 -> $(metric hf-hub hit)"
