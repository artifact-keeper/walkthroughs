#!/usr/bin/env bash
# G5 Hosted models: publish to hf-local file by file, who may publish, and what a client can
# do with the result. Each run publishes a new model, acme/g5-<RUNID>.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G5
MODEL=acme/g5-$RUNID
SRC="$ROOT/out/models/embedder"
[[ -s $SRC/config.json ]] || { fail $G "the model to publish exists ($SRC)" "run make host first"; exit 0; }
up() { call "$1" POST "$HFAPI/$2/api/models/$MODEL/upload/main" -H "X-Filename: $3" --data-binary "@$SRC/$3" >/dev/null; }
n=0 bad=0
while read -r f; do up publisher hf-local "$f"; n=$((n + 1)); [[ $(code) == 200 ]] || { bad=$((bad + 1)); why; }; done \
  < <(cd "$SRC" && find . -type f | sed 's|^\./||' | sort)
check $G "the publisher uploads all $n files with X-Filename (200 each)" "$bad failed" test "$bad" -eq 0
up publisher hf-local config.json
check $G "re-publishing a file at the same revision is 409" "$(why)" is 409
up developer hf-local README.md
check $G "a user without write permission cannot publish (403)" "$(why)" is 403
up publisher-read hf-local README.md
check $G "a token without the write:artifacts scope cannot publish, even with write permission (403)" "$(why)" is 403
up - hf-local README.md
check $G "anonymous publish is 401" "$(why)" is 401
up admin hf-lab README.md
check $G "publishing to a Remote is 405, even for an admin" "$(why)" is 405
up admin hf-models README.md
check $G "publishing to a Virtual is 400, even for an admin" "$(why)" is 400
bad=0
for f in config.json model.safetensors 1_Pooling/config.json; do
  hf developer hf-local -h "g5-$RUNID" -- download "$MODEL" "$f" > "$GOUT/g5-dl.json"
  [[ $(jq -r .sha256 "$GOUT/g5-dl.json") == $(sha256sum "$SRC/$f" | cut -d' ' -f1) ]] || { bad=$((bad + 1)); hfwhy "$GOUT/g5-dl.json"; }
done
check $G "hf_hub_download returns the published bytes (sha256 of 3 files, one in a subdirectory)" "$bad mismatches" test "$bad" -eq 0
hf developer hf-local -h "g5-$RUNID" -- automodel "$MODEL" > "$GOUT/g5-auto.json"; cat "$GOUT/g5-auto.json"
check $G "AutoModel.from_pretrained loads the hosted model" "$(hfwhy "$GOUT/g5-auto.json")" ok "$GOUT/g5-auto.json"
hf developer hf-local -h "g5-$RUNID" -- encode "$MODEL" > "$GOUT/g5-enc.json"; cat "$GOUT/g5-enc.json"
check $G "SentenceTransformer loads the hosted model" "$(hfwhy "$GOUT/g5-enc.json")" ok "$GOUT/g5-enc.json"
hf developer hf-local -h "g5-snap-$RUNID" -- snapshot "$MODEL" > "$GOUT/g5-snap.json"; jq -c '{ok, commit, files, error, msg}' "$GOUT/g5-snap.json"
want=$(cd "$SRC" && find . -type f | sed 's|^\./||' | sort | jq -R . | jq -sc .)
if jq -e --argjson w "$want" '.ok and (.files | sort) == ($w | sort)' "$GOUT/g5-snap.json" >/dev/null; then
  pass $G "snapshot_download of a hosted model returns every file"
else
  blocked ak-fix $G "snapshot_download of a hosted model returns every file" \
    "hosted model info has no id, lists stored paths, and its sha cannot be resolved (findings F1, $AK_HOSTED_SNAPSHOT_ISSUE)"
fi
