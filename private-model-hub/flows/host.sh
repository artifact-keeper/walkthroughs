#!/usr/bin/env bash
# Step 5: host your own models. hf-local is a Local repository. A training job (here: the
# workstation saving acme-lab/tiny-st as acme/embedder) publishes its files one at a time with
# Artifact Keeper's upload route; developers download them with huggingface_hub. hf-models
# is a Virtual of hf-local and hf-lab.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODEL=acme/embedder

say "hf-local (Local) and hf-models (Virtual: hf-local, then hf-lab)"
ensure_repo hf-local '{"key":"hf-local","name":"Acme models","format":"huggingface","repo_type":"local","visibility":"private"}'
ensure_repo hf-models '{"key":"hf-models","name":"Acme models, then the lab Hub","format":"huggingface",
  "repo_type":"virtual","visibility":"private","member_repos":[{"repo_key":"hf-local","priority":1},{"repo_key":"hf-lab","priority":2}]}'
grant user publisher hf-local '["read","write"]'
for r in hf-local hf-models; do grant user developer "$r" '["read"]'; done

say "the training job's output: $MODEL in out/models/embedder"
rm -rf "$ROOT/out/models/embedder"; mkdir -p "$ROOT/out/models"
hf developer hf-lab -h trainer -- save "$LAB_MODEL" /out/models/embedder | jq -c '{ok, files}'

say "publish it file by file (publisher token, write:artifacts)"
publish() { # DIR MODEL REVISION
  local dir=$1 model=$2 rev=$3 f
  (cd "$dir" && find . -type f | sed 's|^\./||' | sort) | while read -r f; do
    call publisher POST "$HFAPI/hf-local/api/models/$model/upload/$rev" -H "X-Filename: $f" \
      --data-binary "@$dir/$f" >/dev/null
    printf '  %-32s HTTP %s %s\n' "$f" "$(code)" "$(jq -c '{path, size}' "$FOUT/.body" 2>/dev/null || cat "$FOUT/.body")"
  done
}
publish "$ROOT/out/models/embedder" "$MODEL" main

say "the developer uses it"
hf developer hf-local -h dev-local -- download "$MODEL" config.json | jq -c '{ok, commit, sha256}'
hf developer hf-local -h dev-local -- automodel "$MODEL"
hf developer hf-local -h dev-local -- encode "$MODEL"
echo "-- snapshot_download (needs the hosted snapshot fix; see the findings):"
hf developer hf-local -h dev-local-snap -- snapshot "$MODEL" | jq -c '{ok, commit, files, error, msg}' || true
show developer GET "$HFAPI/hf-local/api/models/$MODEL/revision/main" >/dev/null
jq -c '{sha, siblings: [.siblings[0:3][] | .rfilename]}' "$FOUT/.body"

say "through the Virtual: hf_hub_download works, snapshot_download does not (documented)"
hf developer hf-models -h dev-virtual -- download "$MODEL" config.json | jq -c '{ok, commit}'
hf developer hf-models -h dev-virtual -- download "$LAB_MODEL" config.json | jq -c '{ok, commit}'
hf developer hf-models -h dev-virtual-snap -- snapshot "$LAB_MODEL" | jq -c '{ok, error, msg}' || true
