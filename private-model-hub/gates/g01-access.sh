#!/usr/bin/env bash
# G1 Access: who may read a private Hugging Face repository, with which token.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G1
R=$HFAPI/hf-lab
call - GET "$R/api/models/$LAB_MODEL/revision/main" >/dev/null; why
check $G "anonymous model info on a private repository is 401" "$(why)" is 401
call - GET "$R/$LAB_MODEL/resolve/main/config.json" >/dev/null; why
check $G "anonymous download from a private repository is 401" "$(why)" is 401
# A real-looking Hugging Face token, made up here (never a real one): what a client sends when
# ~/.cache/huggingface/token from an earlier `hf auth login` is still in place.
fake="hf_$(openssl rand -hex 17)"
call "raw:$fake" GET "$R/api/models/$LAB_MODEL/revision/main" >/dev/null; why
check $G "a Hugging Face token (hf_...) is refused with 401, not passed on" "$(why)" is 401
call developer GET "$R/api/models/$LAB_MODEL/revision/main" >/dev/null
check $G "a read:artifacts token reads model info (200)" "$(why)" is 200
hf developer hf-lab -h g1 -- download "$LAB_MODEL" config.json > "$GOUT/g1-download.json"; cat "$GOUT/g1-download.json"
check $G "hf_hub_download with HF_TOKEN = an Artifact Keeper read:artifacts token works" "$(hfwhy "$GOUT/g1-download.json")" ok "$GOUT/g1-download.json"
call developer HEAD "$R/$LAB_MODEL/resolve/main/config.json" >/dev/null
echo "HEAD: HTTP $(code) ETag $(hdr ETag) X-Repo-Commit $(hdr X-Repo-Commit)"
check $G "a resolve HEAD carries the ETag and X-Repo-Commit huggingface_hub needs" "HTTP $(code)" \
  bash -c "[[ \$(cat '$FOUT/.code') == 200 ]] && grep -qi '^etag:' '$FOUT/.headers' && grep -qiE '^x-repo-commit: [0-9a-f]{40}' '$FOUT/.headers'"
call bob GET "$HFAPI/hf-local/api/models/acme/embedder/revision/main" >/dev/null; why
check $G "a user with no grant on a private repository gets 404 (its existence is not disclosed)" "$(why)" is 404
