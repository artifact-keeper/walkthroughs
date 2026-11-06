#!/usr/bin/env bash
# Step 6: pi, an open-source coding agent, on the site network.
#   0. a clean npm install of pi in a fresh node container, from npm-remote alone;
#   1. the pi image built while seeding: its version and its offline settings;
#   2. the lab's bridge (pi/bridge.py; pi has no marketplace client): offgrid-ops from the
#      plugins Remote, SHA-256 checked, its MCP servers checked against mcp-all, pi's mcp.json;
#   3. pi mcp list: pi starts acme-inventory and lists its tools;
#   4. models.json: the local model on llama-server's OpenAI-compatible API;
#   5. the stock question, with the plugin's skill appended to pi's system prompt;
#   6. best-effort, not gated: a write-then-run coding task (a 1.5B model does not do it).
# Results in out/pi/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $(phase) == site ]] || { echo "pi.sh: run make disconnect first" >&2; exit 1; }
PO="$ROOT/out/pi"; rm -rf "$PO"; mkdir -p "$PO"
IMG=localhost/ak-offgrid/pi:latest
podman image exists "$IMG" || { echo "pi.sh: no pi image (make seed builds it; out/flows/pi-build.log)" >&2; exit 1; }
H="$ROOT/out/homes/pi"
rm -rf "$H"; mkdir -p "$H"
QUESTION=${QUESTION:-How many units of SKU OG-1138 are in the north warehouse?}
prun() { "$ROOT/pi/run.sh" "$@"; }

say "0. a clean install of pi from npm-remote, on the site"
node_ref=$(manifest '.image[] | select(.name == "node") | .ref')
pv=$(manifest '.npm[] | select(.name == "@earendil-works/pi-coding-agent") | .version')
AK_TOKEN=$(tok developer) podman run --rm -i --network "$NET" -e AK_TOKEN -e PV="$pv" \
  -e PI_OFFLINE=1 -e PI_TELEMETRY=0 -e PI_SKIP_VERSION_CHECK=1 \
  -v "$CA:/ca.crt:ro,z" "$P/oci-dockerhub/$node_ref" bash -euc '
  export NODE_EXTRA_CA_CERTS=/ca.crt
  r=ak.internal/npm/npm-remote/
  printf "registry=https://%s\n//%s:_authToken=%s\n" "$r" "$r" "$AK_TOKEN" > /tmp/npmrc
  t=$(date +%s)
  npm install -g --userconfig /tmp/npmrc --no-fund --no-audit "@earendil-works/pi-coding-agent@$PV" 2>&1 | grep -E "^(added|changed|npm error)" || true
  echo "node $(node --version), $(du -sm /usr/local/lib/node_modules/@earendil-works | cut -f1) MB installed"
  echo "pi --version: $(pi --version) ($(( $(date +%s) - t )) s)"' 2>&1 | tee "$PO/npm-install.txt"

say "1. the pi image (built while seeding), and its offline settings"
prun sh -c 'echo "pi --version: $(pi --version)"; env | grep -E "^PI_" | sort' | tee "$PO/image.txt"
podman image inspect "$IMG" --format '{{json .Config.Env}}' > "$PO/image-env.json"

say "2. the bridge: offgrid-ops from the plugins Remote into pi's mcp.json (a lab step, not a pi feature)"
prun python3 /opt/pi/bridge.py offgrid-ops > "$PO/bridge.json" 2> "$PO/bridge.err" || true
jq -r '"  index.json latest \(.plugin.version): sha256 \(.plugin.index_sha256)",
       "  zip sha256 \(.plugin.sha256): \(if .plugin.verified then "matches" else "DOES NOT MATCH" end)",
       "  unzipped into \(.plugin.dir): \(.plugin.files | join(", "))",
       (.servers[] | "  \(.server): \(.distribution) \(.version) -> mcp-all \(.registry_name // "not listed"); in pi mcp.json: \(.configured)"),
       "  wrote \(.mcp_json.path): \(.mcp_json.mcpServers | tojson)", .error // empty' "$PO/bridge.json" 2>/dev/null \
  || { cat "$PO/bridge.err"; exit 1; }
cp "$H/.pi/agent/mcp.json" "$PO/mcp.json"
SKILL=$(jq -r .skill "$PO/bridge.json")

say "3. pi mcp list"
echo '$ pi mcp list'
prun pi mcp list 2>&1 | tee "$PO/mcp-list.txt" || true
prun pi mcp list --json > "$PO/mcp-list.json" 2> "$PO/mcp-list.err" || true

say "4. models.json: the local model, on llama-server's OpenAI-compatible API"
jq -n --arg u "http://$LLAMA:8080/v1" --arg name "$MODEL_GGUF" --argjson ctx "${LLAMA_CTX:-32768}" '{providers: {offgrid: {
  baseUrl: $u, api: "openai-completions", apiKey: "local",
  models: [{id: "local", name: $name, contextWindow: $ctx, maxTokens: 2048, reasoning: false, input: ["text"]}]}}}' \
  > "$H/.pi/agent/models.json"
cp "$H/.pi/agent/models.json" "$PO/models.json"
jq -c . "$PO/models.json"

say "5. the stock question, with the plugin's skill"
args=(--mode json --model offgrid/local --no-builtin-tools --no-skills --append-system-prompt "$SKILL")
echo "\$ pi ${args[*]/#\/home\/dev/\~} \"$QUESTION\" | jq -rf pi/transcript.jq"
t=$SECONDS
prun timeout 900 pi "${args[@]}" "$QUESTION" > "$PO/session.jsonl" 2> "$PO/session.err" || true
echo "$((SECONDS - t))" > "$PO/session.seconds"
jq -rf "$ROOT/pi/transcript.jq" "$PO/session.jsonl" 2>/dev/null | sed 's/^/  /' || tail -c 400 "$PO/session.err"
echo "  ($((SECONDS - t)) s)"

say "6. best-effort, not gated: a write-then-run coding task with pi's own tools"
# With the 1.5B model pi's read tool works, but writing a file and then running it does not
# (it prints the tool calls as text). Qwen2.5-7B-Instruct does it; see the page.
mkdir -p "$H/work"
t=$SECONDS
prun sh -c 'cd /home/dev/work && timeout 600 pi --mode json --model offgrid/local --no-mcp --no-skills \
  "Create hello.py that prints 42, then run it with python3 and tell me the output."' > "$PO/coding.jsonl" 2> "$PO/coding.err" || true
calls=$(jq -r 'select(.type == "tool_execution_start") | .toolName' "$PO/coding.jsonl" 2>/dev/null | paste -sd, -)
out=$(prun sh -c 'cd /home/dev/work && if [ -f hello.py ]; then timeout 10 python3 hello.py 2>&1; else echo "no hello.py"; fi' | tail -1)
said=$(jq -rs '[.[] | select(.type == "message_end" and .message.role == "assistant")] | last | [.message.content[]? | select(.type == "text") | .text] | join("") | gsub("\\s+"; " ") | .[0:200]' "$PO/coding.jsonl" 2>/dev/null || true)
jq -n --arg calls "$calls" --arg out "$out" --arg said "$said" --argjson s "$((SECONDS - t))" \
  '{tool_calls: $calls, hello_py_output: $out, ok: ($out == "42" and ($calls | split(",") | index("write") != null and index("bash") != null)), seconds: $s, answer: $said}' | tee "$PO/coding.json" | jq -c .
