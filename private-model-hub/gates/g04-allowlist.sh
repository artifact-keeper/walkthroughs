#!/usr/bin/env bash
# G4 Approved sources: hf-curated fetches only approved organizations, for both path shapes.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G4
R=$HFAPI/hf-curated
api GET /repositories/hf-curated/upstream-filter | jq -c '{include_patterns, active}'
hf developer hf-curated -h "g4-$RUNID" -- snapshot "$LAB_MODEL" > "$GOUT/g4-ok.json"; jq -c '{ok, commit}' "$GOUT/g4-ok.json"
check $G "an approved organization (acme-lab) resolves through hf-curated" "$(hfwhy "$GOUT/g4-ok.json")" ok "$GOUT/g4-ok.json"
since=$(date -u +%FT%TZ)
for m in evil-org/backdoor sentence-transformer/all-MiniLM-L6-v2; do
  call developer GET "$R/api/models/$m/revision/main" >/dev/null
  check $G "model info for $m is refused (404)" "$(why)" is 404
  call developer GET "$R/$m/resolve/main/config.json" >/dev/null
  check $G "a file of $m is refused (404)" "$(why)" is 404
done
call developer GET "$R/acme-lab-evil/tiny-st/resolve/main/config.json" >/dev/null
check $G "a name that only starts with an approved organization (acme-lab-evil/...) is refused" "$(why)" is 404
n=$(lab_log "$since" | grep -c -e evil-org -e sentence-transformer/ -e acme-lab-evil || true)
check $G "the refused names never reached the lab Hub" "$n upstream requests" test "$n" -eq 0
call developer GET "$HFAPI/hf-lab/api/models/evil-org/backdoor/revision/main" >/dev/null
check $G "control: the same name through hf-lab (no filter) is 200, so the filter is what refused it" "$(why)" is 200
