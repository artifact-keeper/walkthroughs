#!/usr/bin/env bash
# G3 Gated models: the Remote holds the Hub token; only ml-team reads it; client tokens are
# never forwarded upstream.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G3
GATED=acme-lab/gated-llm
since=$(date -u +%FT%TZ)
call developer GET "$HFAPI/hf-lab/api/models/$GATED/revision/main" >/dev/null; why
check $G "without upstream auth the gated model is refused (hf-lab answers 502, the Hub said 401)" "$(why)" is 502
hf alice hf-lab-gated -h "g3-alice-$RUNID" -- snapshot "$GATED" > "$GOUT/g3-alice.json"; jq -c '{ok, commit, files}' "$GOUT/g3-alice.json"
check $G "alice (group ml-team) downloads the gated model through hf-lab-gated" "$(hfwhy "$GOUT/g3-alice.json")" ok "$GOUT/g3-alice.json"
hf alice hf-lab-gated -h "g3-alice-$RUNID" -- encode "$GATED" > "$GOUT/g3-alice-encode.json"
check $G "alice loads it with sentence-transformers" "$(hfwhy "$GOUT/g3-alice-encode.json")" ok "$GOUT/g3-alice-encode.json"
call bob GET "$HFAPI/hf-lab-gated/api/models/$GATED/revision/main" >/dev/null; why
check $G "bob (not in ml-team) is refused with 404" "$(why)" is 404
call developer GET "$HFAPI/hf-lab-gated/$GATED/resolve/main/config.json" >/dev/null; why
check $G "the developer (read on hf-lab, not on hf-lab-gated) is refused with 404" "$(why)" is 404
lab_log "$since" > "$GOUT/g3-lab.log"
hub=$(fp "$(<"$TOKENS/lab-hub.token")")
n_hub=$(jq -r --arg f "$hub" 'select(.path | test("gated-llm")) | select(.auth == $f) | .path' "$GOUT/g3-lab.log" | wc -l)
n_cli=0
for t in alice bob developer; do n_cli=$(( n_cli + $(grep -c "\"auth\": \"$(fp "$(tok "$t")")\"" "$GOUT/g3-lab.log" || true) )); done
echo "lab Hub requests for the gated model with the repository's Hub token: $n_hub; with a client token: $n_cli"
check $G "upstream requests for the gated model carry the repository's Hub token" "$n_hub requests" test "$n_hub" -gt 0
check $G "no client token (alice, bob, developer) ever reaches the lab Hub" "$n_cli requests" test "$n_cli" -eq 0
api GET /repositories/hf-lab-gated > "$GOUT/g3-repo.json"
check $G "the repository API reports upstream auth as configured and never returns the Hub token" "see log" \
  bash -c "jq -e '.upstream_auth_configured == true' '$GOUT/g3-repo.json' >/dev/null && ! grep -qF \"\$(cat '$TOKENS/lab-hub.token')\" '$GOUT/g3-repo.json'"
