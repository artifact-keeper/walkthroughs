#!/usr/bin/env bash
# Step 4: approve model sources. hf-curated is a Remote of the lab Hub with an upstream
# filter: only the approved organizations (acme-lab and sentence-transformers) are ever
# fetched. The Hub API has two path shapes, model info (api/models/<org>/<name>/...) and
# files (<org>/<name>/resolve/...), so each organization needs a pattern for both.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

say "hf-curated: the lab Hub, approved organizations only"
ensure_repo hf-curated "$(jq -nc --arg u "http://$LAB_IP:8080" '{key:"hf-curated",
  name:"The lab Hub, approved organizations only",format:"huggingface",repo_type:"remote",
  upstream_url:$u,visibility:"private"}')"
FILTER='{"include_patterns":[
  "^api/models/(acme-lab|sentence-transformers)/[^/]+(/(revision|tree)/[^/]+)?$",
  "^(acme-lab|sentence-transformers)/[^/]+/resolve/"
]}'
api PUT /repositories/hf-curated/upstream-filter -d "$FILTER" | jq .
grant user developer hf-curated '["read"]'

say "an approved organization resolves"
hf developer hf-curated -h curated -- snapshot "$LAB_MODEL" | jq -c '{ok, commit, files: (.files | length)}'

say "everything else is refused before Artifact Keeper contacts the Hub"
since=$(date -u +%FT%TZ)
for m in evil-org/backdoor sentence-transformer/all-MiniLM-L6-v2; do
  echo "-- $m"
  show developer GET "$HFAPI/hf-curated/api/models/$m/revision/main"
  hf developer hf-curated -h curated -- download "$m" config.json || true
done
echo "lab Hub requests for the refused names: $(lab_log "$since" | grep -c -e evil-org -e sentence-transformer/ || true)"
echo "-- the same two names through hf-lab, which has no filter:"
for m in evil-org/backdoor sentence-transformer/all-MiniLM-L6-v2; do
  call developer GET "$HFAPI/hf-lab/api/models/$m/revision/main" >/dev/null; echo "hf-lab $m: HTTP $(code)"
done
