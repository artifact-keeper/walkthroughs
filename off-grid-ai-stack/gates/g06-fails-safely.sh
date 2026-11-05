#!/usr/bin/env bash
# G6 Fails safely: on the site, anything that was not seeded is a clean, fast 404 (no wait on
# an upstream that is not there), an unapproved MCP server is not served, a manual MCP sync
# does not go out, the agent refuses an MCP server its registry does not list, and the agent's
# own container has no route out.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_site
G=G6
before=$(metric ak_proxy_cache_lookups_total 'result="cache_only_miss"')
for t in \
  "a model file nobody seeded (hf-hub)|/huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  "a PyPI project nobody seeded (pypi Virtual)|/pypi/pypi/simple/rich-click/" \
  "an image tag nobody seeded (oci-ghcr)|/v2/oci-ghcr/ggml-org/llama.cpp/manifests/server-b5000" \
  "an npm package nobody seeded (npm-remote)|/npm/npm-remote/left-pad" \
  "a plugin version nobody published (plugins Remote)|/agentplugins/plugins/offgrid-ops/9.9.9/offgrid-ops-9.9.9.zip"; do
  name=${t%%|*} path=${t#*|}
  ms=$(ms_of call developer GET "$path" -o /dev/null)
  echo "$name: GET $path -> HTTP $(code) in $ms ms"
  check $G "$name: 404 in under 2 s" "HTTP $(code) after $ms ms" bash -c "[[ \$(cat '$FOUT/.code') == 404 ]] && (( $ms < 2000 ))"
done
# A cold HEAD (a HEAD for a file the cache does not hold) is the one upstream probe the
# UPSTREAM_FETCHED audit event does not record yet (artifact-keeper#5347). On a cache-only
# Remote it must not happen at all: the ledger, which sees every connection, must stay put.
lh0=$(ledger_lines)
for t in "hf-hub|/huggingface/hf-hub/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/README.md" \
         "oci-ghcr|/v2/oci-ghcr/ggml-org/llama.cpp/manifests/server-b5001" \
         "pypi-remote|/pypi/pypi-remote/simple/rich-click/"; do
  ms=$(ms_of call developer HEAD "${t#*|}")
  echo "cold HEAD ${t%%|*} ${t#*|}: HTTP $(code) in $ms ms"
  check $G "a cold HEAD on ${t%%|*} for something nobody seeded: 404, fast" "HTTP $(code) after $ms ms" \
    bash -c "[[ \$(cat '$FOUT/.code') == 404 ]] && (( $ms < 2000 ))"
done
sleep 2; lh1=$(ledger_lines)
check $G "the cold HEADs opened no connection (the probe #5347 leaves out of the audit log never ran)" "ledger $lh0 -> $lh1" test "$lh1" -eq "$lh0"
after=$(metric ak_proxy_cache_lookups_total 'result="cache_only_miss"')
echo "ak_proxy_cache_lookups_total{result=\"cache_only_miss\"}: $before -> $after"
check $G "the misses are counted as cache_only_miss (they never tried an upstream)" "$before -> $after" test "$after" -gt "$before"

show developer GET "/mcp/mcp-all/v0.1/servers/io.github.tonydzi%2Fsqlite-graph-memory/versions/latest" | head -c 200; echo
check $G "an MCP server the curator did not approve is not served by mcp-all" "HTTP $(code)" is 404

l0=$(ledger_lines); f0=$(audit_count UPSTREAM_FETCHED "$(jq -r .at "$DISC")")
show admin POST /api/v1/repositories/mcp-official/mcp/seed -d '{"servers":[{"name":"io.github.daedalus/mcp-sympy","version":"0.1.0"}],"reason":"G6: must be refused offline"}' -H 'Content-Type: application/json' | head -c 300; echo
seed_code=$(code)
check $G "a targeted MCP seed on the site is refused (409: the Remote is cache-only, #5408)" "HTTP $seed_code" test "$seed_code" == 409
show admin POST /api/v1/repositories/mcp-official/mcp/sync | head -c 300; echo
sync_code=$(code)
sleep 2
l1=$(ledger_lines); f1=$(audit_count UPSTREAM_FETCHED "$(jq -r .at "$DISC")")
echo "manual MCP sync: HTTP $sync_code; ledger $l0 -> $l1; UPSTREAM_FETCHED since the disconnect $f0 -> $f1"
check $G "a manual MCP seed and sync on the site send nothing upstream" "ledger $l0 -> $l1, UPSTREAM_FETCHED $f0 -> $f1" \
  test "$l1" -eq "$l0" -a "$f1" -eq "$f0"

"$RUN" -h g6-agent -e MCP_REPO=mcp-internal -- python /opt/agent/agent.py --max-turns 1 \
  --question "List the warehouses." > "$GOUT/g6-agent.json" 2> "$GOUT/g6-agent.log" || true
jq -c '[.steps[] | select(.step | startswith("mcp-")) | {step, server, registry_name}]' "$GOUT/g6-agent.json"
check $G "the agent does not start an MCP server its registry does not list (registry mcp-internal only: sqlite refused)" \
  "$(jq -c '[.steps[] | select(.step | startswith("mcp-")) | {step, server}]' "$GOUT/g6-agent.json")" \
  jq -e 'any(.steps[]; .step == "mcp-refused" and .server == "sqlite") and all(.steps[] | select(.step == "mcp-started"); .server != "sqlite")' "$GOUT/g6-agent.json"

"$RUN" -- python -c '
import socket, sys
bad = []
for host, port in (("1.1.1.1", 443), ("8.8.8.8", 53), ("huggingface.co", 443), ("pypi.org", 443), ("registry.modelcontextprotocol.io", 443)):
    try:
        socket.create_connection((host, port), timeout=5).close(); bad.append(host)
    except OSError as e:
        print(host, "unreachable:", type(e).__name__)
sys.exit(1 if bad else 0)'
check $G "the agent's container has no route out (1.1.1.1, 8.8.8.8, huggingface.co, pypi.org, the MCP registry)" "a host answered" test $? -eq 0
