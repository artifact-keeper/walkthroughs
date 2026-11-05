#!/usr/bin/env bash
# Step 5: the AI stack on the site network, from Artifact Keeper alone.
#   1. the llama.cpp and python images: removed from the host's image store, pulled again
#      through oci-ghcr and oci-dockerhub (cache-only), and checked against the seed's digests;
#   2. the model: hf download from hf-models into out/models/site/ in the agent container;
#   3. llama-server on ak-offgrid-site, with that file;
#   4. a clean install of every Python package of the agent from the pypi Virtual, in a fresh
#      container, hash-checked (pip --require-hashes);
#   5. the agent: installs its plugin from the plugins Remote, checks its MCP servers against
#      mcp-all, starts them, and answers a stock question with a tool call to the local model.
# Results in out/agent/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $(phase) == site ]] || { echo "agent.sh: run make disconnect first; the agent runs on the site network" >&2; exit 1; }
AO="$ROOT/out/agent"; mkdir -p "$AO" "$ROOT/out/models/site"
lref=$(manifest '.image[] | select(.name == "llama-server") | .ref')
pyref=$(manifest '.image[] | select(.name == "python") | .ref')

say "1. the llama.cpp server image and the python base image, pulled again through the registry"
podman rm -f -t 0 --ignore "$LLAMA" >/dev/null
podman rmi -f "$P/oci-ghcr/$lref" >/dev/null 2>&1 || true
t=$SECONDS; d=$(pull_image oci-ghcr "$lref")
seed_d=$(awk -F'\t' -v r=oci-ghcr -v n="$lref" '$1 == r && $2 == n {print $3}' "$ROOT/out/seed-images.tsv")
echo "  $P/oci-ghcr/$lref: $d ($((SECONDS - t)) s); pulled while seeding: $seed_d"
echo "$d" > "$AO/llama-image.digest"
podman rmi -f "$P/oci-dockerhub/$pyref" >/dev/null 2>&1 || true
t=$SECONDS; d2=$(pull_image oci-dockerhub "$pyref")
echo "  $P/oci-dockerhub/${pyref:0:40}...: $d2 ($((SECONDS - t)) s)"
echo "$d2" > "$AO/python-image.digest"

say "2. the model from hf-models ($MODEL_REPO, $MODEL_GGUF)"
rm -f "$ROOT/out/models/site/$MODEL_GGUF"
"$RUN" -h agent-hf -- bash -c "hf download '$MODEL_REPO' '$MODEL_GGUF' --local-dir /out/models/site 2>&1 | tail -1" | tee "$AO/model-download.txt"
sha=$(sha256sum "$ROOT/out/models/site/$MODEL_GGUF" | cut -d' ' -f1)
echo "  sha256 $sha"; echo "$sha" > "$AO/model.sha256"

say "3. llama-server on $NET"
podman run -d --name "$LLAMA" --network "$NET" --label ak-offgrid=llama \
  -v "$ROOT/out/models/site:/models:ro,z" "$P/oci-ghcr/$lref" \
  -m "/models/$MODEL_GGUF" --alias local --jinja -c "${LLAMA_CTX:-32768}" -t "${LLAMA_THREADS:-16}" \
  --host 0.0.0.0 --port 8080 >/dev/null
for i in $(seq 120); do
  "$RUN" -n "$NET" -- python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://$LLAMA:8080/health',timeout=3).status==200 else 1)" 2>/dev/null && break
  sleep 2
done
"$RUN" -- python -c "import json,urllib.request; print('  /health', urllib.request.urlopen('http://$LLAMA:8080/health').read().decode()); print('  /v1/models', [m['id'] for m in json.load(urllib.request.urlopen('http://$LLAMA:8080/v1/models'))['data']])"

say "4. a clean install of the agent's packages, from the registry alone"
AK_TOKEN=$(tok developer) podman run --rm -i --network "$NET" -e AK_TOKEN \
  -v "$CA:/ca.crt:ro,z" -v "$ROOT/agent:/agent:ro,z" "$P/oci-dockerhub/$pyref" bash -euc '
  export PIP_CERT=/ca.crt PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore
  idx="https://developer:$AK_TOKEN@ak.internal/pypi/pypi/simple/"
  t=$(date +%s)
  pip install -q --require-hashes --index-url "$idx" -r /agent/requirements.lock
  pip install -q --require-hashes --no-deps --index-url "$idx" -r /agent/requirements-internal.txt
  pip check
  echo "installed $(pip list --format freeze | wc -l) distributions in $(( $(date +%s) - t )) s"' 2>&1 | tail -3 | tee "$AO/clean-install.txt"

say "5. the agent"
"$RUN" -h agent -- python /opt/agent/agent.py ${QUESTION:+--question "$QUESTION"} > "$AO/run.json" 2> "$AO/run.log" || true
cat "$AO/run.log" | sed 's/^/  /'
jq -c '{ok, error, plugin, servers, tool_calls: [.tool_calls[]? | {tool, arguments, result: (.result[0:120])}], answer, model, seconds}' "$AO/run.json"
