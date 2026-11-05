#!/usr/bin/env bash
# G4 Agent: on the site network, the whole AI stack comes from Artifact Keeper: the model
# server's image, the model, every Python package, the plugin, the MCP servers and their
# registry entries; and the agent answers a question through a tool call to the local model.
# Reads what flows/agent.sh left in out/agent/ (make agent); re-checks the live pieces.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_site
G=G4
AO="$ROOT/out/agent"; INV="$ROOT/out/inventory/seed.tsv"
lref=$(manifest '.image[] | select(.name == "llama-server") | .ref')
pyref=$(manifest '.image[] | select(.name == "python") | .ref')
for t in "oci-ghcr|$lref|llama-image" "oci-dockerhub|$pyref|python-image"; do
  IFS='|' read -r repo ref f <<<"$t"
  seed_d=$(awk -F'\t' -v r="$repo" -v n="$ref" '$1 == r && $2 == n {print $3}' "$ROOT/out/seed-images.tsv")
  site_d=$(cat "$AO/$f.digest" 2>/dev/null)
  echo "$repo/${ref:0:50}: pulled while seeding $seed_d, on the site $site_d"
  check $G "the ${f%-image} image was pulled again on the site, through $repo, at the seed's digest" "seed $seed_d site $site_d" \
    test -n "$site_d" -a "$site_d" == "$seed_d"
done
seed_m=$(awk -F'\t' -v n="hf-models:$MODEL_REPO/$MODEL_GGUF" '$1 == "model" && $2 == n {print $3}' "$INV")
site_m=$(cat "$AO/model.sha256" 2>/dev/null)
check $G "the model was downloaded on the site from hf-models with hf download, at the seed's SHA-256" "seed $seed_m site $site_m" \
  test -n "$site_m" -a "$site_m" == "$seed_m"
"$RUN" -- python -c "import json,urllib.request; print(json.dumps({'health': json.load(urllib.request.urlopen('http://$LLAMA:8080/health')), 'models': [m['id'] for m in json.load(urllib.request.urlopen('http://$LLAMA:8080/v1/models'))['data']]}))" > "$GOUT/g4-llama.json" 2>&1
cat "$GOUT/g4-llama.json"
check $G "llama-server runs on the site network and serves the model" "$(head -c 200 "$GOUT/g4-llama.json")" \
  jq -e '.health.status == "ok" and (.models | length) > 0' "$GOUT/g4-llama.json"
cat "$AO/clean-install.txt" 2>/dev/null
check $G "a clean, hash-checked install of every agent package from the pypi Virtual works on the site" "$(tail -1 "$AO/clean-install.txt" 2>/dev/null)" \
  grep -qE '^installed [0-9]+ distributions' "$AO/clean-install.txt"

R="$AO/run.json"
jq -c '{ok, error, plugin, servers: (.servers | keys?), sqlite_check, tool_calls: [.tool_calls[]? | {tool, arguments}], answer, seconds}' "$R" 2>/dev/null || cat "$R"
check $G "the agent installed offgrid-ops from the plugins Remote and verified its SHA-256 against the index" "$(jq -c '.steps[]? | select(.step == "plugin")' "$R")" \
  jq -e 'any(.steps[]; .step == "plugin" and .verified == true)' "$R"
check $G "both MCP servers of the plugin are listed in mcp-all at their installed versions, and started" "$(jq -c '[.steps[] | select(.step | startswith("mcp-")) | {step, server, distribution, version, registry_name}]' "$R")" \
  jq -e '[.steps[] | select(.step == "mcp-started") | .registry_name] | sort == ["com.acme/inventory", "io.github.daedalus/mcp-sqlite3"]' "$R"
check $G "the public server (mcp-sqlite3, from the official registry) answers a tool call offline" "$(jq -c .sqlite_check "$R")" \
  jq -e '(.sqlite_check // "") | test("[0-9]+\\.[0-9]+")' "$R"
check $G "the local model called stock_level for OG-1138 in north" "$(jq -c '[.tool_calls[]? | {tool, arguments}]' "$R")" \
  jq -e 'any(.tool_calls[]?; .tool == "stock_level" and (.arguments.sku | ascii_upcase) == "OG-1138" and (.arguments.warehouse | ascii_downcase) == "north")' "$R"
check $G "the answer gives the tool's number (42 units)" "$(jq -c .answer "$R")" \
  jq -e '(.answer // "") | test("\\b42\\b")' "$R"
if jq -e '(.answer // "") | contains("inv-7f3a9c")' "$R" >/dev/null; then
  pass $G "the answer quotes the tool's ref (inv-7f3a9c), as the plugin's skill asks"
else
  fail $G "the answer quotes the tool's ref (inv-7f3a9c), as the plugin's skill asks" "$(jq -c .answer "$R")"
fi
