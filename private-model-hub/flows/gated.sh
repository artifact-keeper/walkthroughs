#!/usr/bin/env bash
# Step 3: gated and private models. The lab Hub's acme-lab/gated-llm needs a Hub token, as a
# gated Llama or Gemma does on huggingface.co. hf-lab-gated is a second Remote of the lab Hub
# that holds that token (PUT .../upstream-auth); only group ml-team (alice) may read it.
# Clients still send only their own Artifact Keeper token, which is never forwarded.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
GATED=acme-lab/gated-llm

say "without upstream auth: hf-lab cannot fetch the gated model"
show developer GET "$HFAPI/hf-lab/api/models/$GATED/revision/main"

say "hf-lab-gated: a Remote of the lab Hub with its own Hub token, readable by ml-team only"
ensure_repo hf-lab-gated "$(jq -nc --arg u "http://$LAB_IP:8080" '{key:"hf-lab-gated",
  name:"The lab Hub with a Hub token (gated models)",format:"huggingface",repo_type:"remote",
  upstream_url:$u,visibility:"private"}')"
# The Hub token goes in from a file and is never printed; Artifact Keeper never returns it.
api PUT /repositories/hf-lab-gated/upstream-auth \
  -d "$(jq -nc --rawfile t "$TOKENS/lab-hub.token" '{auth_type:"bearer",password:($t|rtrimstr("\n"))}')" >/dev/null
echo "PUT /api/v1/repositories/hf-lab-gated/upstream-auth: HTTP $(code)"
api GET /repositories/hf-lab-gated | jq -c '{key, upstream_auth_type, upstream_auth_configured, visibility}'

if [[ -z $(group_id ml-team) ]]; then
  api POST /groups -d '{"name":"ml-team","description":"May use gated models"}' >/dev/null
  echo "group ml-team: HTTP $(code)"
fi
api POST "/groups/$(group_id ml-team)/members" -d "$(jq -nc --arg u "$(user_id alice)" '{user_ids:[$u]}')" >/dev/null
echo "alice added to ml-team: HTTP $(code)"
grant group ml-team hf-lab-gated '["read"]'

say "alice (ml-team) downloads the gated model"
since=$(date -u +%FT%TZ)
hf alice hf-lab-gated -h alice -- snapshot "$GATED" | jq -c '{ok, commit, files}'
hf alice hf-lab-gated -h alice -- encode "$GATED"
say "bob (not in ml-team) is refused"
hf bob hf-lab-gated -h bob -- download "$GATED" config.json || true
show bob GET "$HFAPI/hf-lab-gated/api/models/$GATED/revision/main"

say "the lab Hub saw the repository's Hub token, never alice's or bob's Artifact Keeper token"
echo "fingerprints: hub token $(fp "$(<"$TOKENS/lab-hub.token")"), alice $(fp "$(tok alice)"), bob $(fp "$(tok bob)")"
lab_log "$since" | jq -r 'select(.path | test("gated-llm|^/cdn/")) |
  (.path | sub("/resolve/.*"; "/resolve/<rev>/<file>") | sub("/revision/.*"; "/revision/<rev>")
   | sub("/tree/.*"; "/tree/<rev>") | sub("^/cdn/.*"; "/cdn/<sha256> (the redirect target)"))
  + "  auth=" + (.auth // "none")' | sort | uniq -c
