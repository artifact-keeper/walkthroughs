#!/usr/bin/env bash
# G8 Fails safely: Xet stays hidden, Virtual repositories behave as documented, interrupted
# downloads resume, traversal and wrong-token writes are refused, and what is not implemented
# answers 404.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G8
R=$HFAPI/hf-lab
# The lab Hub's own answer, read from the workstation on ak-hf-net (the lab is not on the host).
"$RUN" -- python -c "import urllib.request,sys; sys.stdout.write(urllib.request.urlopen('http://$LAB_IP:8080/api/models/$LAB_MODEL/revision/main').read().decode())" > "$GOUT/g8-upstream-info.json"
call developer GET "$R/api/models/$LAB_MODEL/revision/main" > "$GOUT/g8-ak-info.json"
echo "upstream: xetEnabled=$(jq .xetEnabled "$GOUT/g8-upstream-info.json"), siblings with xetHash: $(jq '[.siblings[] | select(.xetHash)] | length' "$GOUT/g8-upstream-info.json")"
echo "via hf-lab: xetEnabled=$(jq .xetEnabled "$GOUT/g8-ak-info.json"), siblings with xetHash: $(jq '[.siblings[] | select(.xetHash)] | length' "$GOUT/g8-ak-info.json")"
check $G "model info: xetHash and xetEnabled, present upstream, are stripped" "see log" \
  bash -c "jq -e '.xetEnabled == true and any(.siblings[]; .xetHash)' '$GOUT/g8-upstream-info.json' >/dev/null && ! grep -q xet '$GOUT/g8-ak-info.json'"
call developer GET "$R/api/models/$LAB_MODEL/tree/main" > "$GOUT/g8-tree.json"
check $G "tree: no xetHash reaches the client" "see log" bash -c "! grep -q xetHash '$GOUT/g8-tree.json'"
call developer HEAD "$R/$LAB_MODEL/resolve/main/model.safetensors" >/dev/null
check $G "a large-file HEAD carries no X-Xet-Hash or xet-auth link" "HTTP $(code)" \
  bash -c "[[ \$(cat '$FOUT/.code') == 200 ]] && ! grep -qi -e '^x-xet' -e 'xet-auth' '$FOUT/.headers'"
call developer GET "$R/api/models/$LAB_MODEL/xet-read-token/main" >/dev/null
check $G "xet-read-token is not proxied (404)" "$(why)" is 404

hf developer hf-models -h "g8-virt-$RUNID" -- snapshot "$LAB_MODEL" > "$GOUT/g8-virt-snap.json"; hfwhy "$GOUT/g8-virt-snap.json"
check $G "a Virtual's snapshot_download fails as documented (model info 404)" "$(hfwhy "$GOUT/g8-virt-snap.json")" \
  jq -e '.ok == false' "$GOUT/g8-virt-snap.json"
hf developer hf-models -h "g8-virt-$RUNID" -- download "$LAB_MODEL" config.json > "$GOUT/g8-virt-dl.json"
check $G "a Virtual's hf_hub_download of a named file works" "$(hfwhy "$GOUT/g8-virt-dl.json")" ok "$GOUT/g8-virt-dl.json"

full="$GOUT/g8-full.bin"
call developer GET "$R/$LAB_MODEL/resolve/main/model.safetensors" >/dev/null; cp "$FOUT/.body" "$full"
size=$(stat -c %s "$full")
call developer GET "$R/$LAB_MODEL/resolve/main/model.safetensors" -H "Range: bytes=1000-" >/dev/null
echo "Range bytes=1000-: HTTP $(code) $(hdr Content-Range)"
check $G "Remote: a resume (Range: bytes=1000-) is 206 with the right bytes" "HTTP $(code) $(hdr Content-Range)" \
  bash -c "[[ \$(cat '$FOUT/.code') == 206 ]] && grep -qi '^content-range: bytes 1000-$((size - 1))/$size' '$FOUT/.headers' && cmp -s <(tail -c +1001 '$full') '$FOUT/.body'"
etag=$(call developer HEAD "$R/$LAB_MODEL/resolve/main/model.safetensors" >/dev/null; hdr ETag)
call developer GET "$R/$LAB_MODEL/resolve/main/model.safetensors" -H "Range: bytes=0-99" -H 'If-Range: "0000"' >/dev/null
check $G "Remote: a resume whose If-Range names another ETag gets the whole file (200)" "$(why)" is 200
call developer GET "$HFAPI/hf-local/acme/embedder/resolve/main/model.safetensors" -H "Range: bytes=-100" >/dev/null
check $G "Local: a suffix range (bytes=-100) is 206 with 100 bytes" "HTTP $(code) $(hdr Content-Range)" \
  bash -c "[[ \$(cat '$FOUT/.code') == 206 && \$(stat -c %s '$FOUT/.body') == 100 ]]"
call developer GET "$HFAPI/hf-local/acme/embedder/resolve/main/model.safetensors" -H "Range: bytes=99999999-" >/dev/null
check $G "Local: a range past the end is 416" "$(why)" is 416

call developer GET "$R/$LAB_MODEL/resolve/main/..%2f..%2f..%2fetc%2fpasswd" >/dev/null
check $G "a ..%2f traversal in the file name is refused (400)" "$(why)" is 400
call developer GET "$R/acme-lab/..%2f..%2fx/resolve/main/config.json" >/dev/null
check $G "a ..%2f traversal in the model id is refused (400)" "$(why)" is 400
call publisher POST "$HFAPI/hf-local/api/models/acme/embedder/upload/main" -H "X-Filename: ../../escape.json" --data-binary '{}' >/dev/null
check $G "an upload whose X-Filename climbs out of the model (../../) is refused (400)" "$(why)" is 400
call developer GET "$R/api/datasets/acme-lab/tiny-st/revision/main" >/dev/null
check $G "datasets are not served (404): models only" "$(why)" is 404
call developer GET "$R/api/whoami-v2" >/dev/null
check $G "account calls (whoami) are not served (404)" "$(why)" is 404
