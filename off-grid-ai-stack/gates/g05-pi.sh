#!/usr/bin/env bash
# G5 pi, an open-source coding agent, on the site network: a clean install of pi from
# npm-remote; the plugin through the lab's bridge (SHA-256 against the index, its skill and
# mcp.json present); pi connected to acme-inventory, with only servers mcp-all lists in its
# mcp.json; a stock_level call in pi's session with the tool's own answer; pi's offline
# settings in the image. The session is PASS or FAIL at the default model size, and
# BLOCKED(best-effort) with SMALL_MODEL=1. The coding task (flows/pi.sh step 6) is shown, not
# gated. Reads what flows/pi.sh left in out/pi/ (make pi).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_site
G=G5
PO="$ROOT/out/pi"
IMG=localhost/ak-offgrid/pi:latest
if ! podman image exists "$IMG"; then
  fail $G "the pi image was built while seeding" "no $IMG (out/flows/pi-build.log)"
  exit 0
fi
pv=$(manifest '.npm[] | select(.name == "@earendil-works/pi-coding-agent") | .version')

# --- 1. the clean install ----------------------------------------------------------------
cat "$PO/npm-install.txt" 2>/dev/null
check $G "a clean npm install of pi $pv from npm-remote works on the site" "$(tail -1 "$PO/npm-install.txt" 2>/dev/null)" \
  grep -qE "^pi --version: $pv " "$PO/npm-install.txt"

# --- 2. the plugin, through the bridge ---------------------------------------------------
B="$PO/bridge.json"
jq -c '.plugin | {name, version, sha256, index_sha256, verified}' "$B" 2>/dev/null || tail -5 "$PO/bridge.err"
check $G "the bridge: the plugin zip's SHA-256 equals the index's (plugins Remote)" "$(jq -c '.plugin // .error' "$B" 2>/dev/null)" \
  jq -e '.plugin.verified == true and .plugin.sha256 == .plugin.index_sha256 and (.plugin.sha256 | length) == 64' "$B"
check $G "the bridge: the plugin's skill and mcp.json are unpacked" "$(jq -c '.plugin.files' "$B" 2>/dev/null)" \
  jq -e '(.plugin.files | index("mcp.json")) and any(.plugin.files[]; test("^skills/[^/]+/SKILL.md$")) and (.skill | type) == "string"' "$B"

# --- 3. pi and its MCP servers -----------------------------------------------------------
cat "$PO/mcp-list.txt" 2>/dev/null
jq -c . "$PO/mcp-list.json" 2>/dev/null || tail -3 "$PO/mcp-list.err" 2>/dev/null
check $G "pi connects to acme-inventory (pi mcp list: list_warehouses, stock_level)" "$(head -c 300 "$PO/mcp-list.json" 2>/dev/null)" \
  jq -e '[.. | objects | select((.name // .server // "") == "acme-inventory")] | any(
           ((.status // .state // "") | tostring | test("connected"))
           and ([.tools[]? | if type == "object" then .name else . end] as $t | ($t | index("list_warehouses")) and ($t | index("stock_level"))))' "$PO/mcp-list.json"
# Every server in pi's mcp.json is listed in mcp-all at the installed version (asked again
# here, not taken from the bridge's report).
call developer GET "/mcp/mcp-all/v0.1/servers?limit=100" > "$GOUT/g5-mcp-all.json"
bad=""; n=0
while IFS=$'\t' read -r name dist ver; do
  n=$((n + 1))
  jq -e --arg d "$dist" --arg v "$ver" 'def norm: ascii_downcase | gsub("[-_.]+"; "-");
      any(.servers[] | (.server // .) | .packages[]?; .registryType == "pypi" and (.identifier | norm) == ($d | norm) and .version == $v)' \
    "$GOUT/g5-mcp-all.json" >/dev/null || bad+="$name($dist $ver) "
  echo "  pi mcp.json: $name -> $dist $ver"
done < <(jq -r --slurpfile m "$PO/mcp.json" '.servers[] | select(.server as $s | $m[0].mcpServers | has($s)) | [.server, .distribution, .version] | @tsv' "$B" 2>/dev/null)
nconf=$(jq '.mcpServers | length' "$PO/mcp.json" 2>/dev/null || echo 0)
check $G "pi's mcp.json holds only servers mcp-all lists at the installed version ($n of $nconf)" "not listed: ${bad:-none}; $n of $nconf matched" \
  test "$nconf" -gt 0 -a "$n" -eq "$nconf" -a -z "$bad"
check $G "pi's mcp.json declares acme-inventory with direct exposure" "$(jq -c . "$PO/mcp.json" 2>/dev/null)" \
  jq -e '.mcpServers["acme-inventory"].exposure == "direct"' "$PO/mcp.json"

# --- 4. the session ----------------------------------------------------------------------
S="$PO/session.jsonl"
jq -c 'select(.type == "tool_execution_start" or .type == "tool_execution_end") | {type, toolName, args, result: ([.result.content[]? | .text // empty] | join(" ") | .[0:160])}' "$S" 2>/dev/null
answer=$(jq -rs '[.[] | select(.type == "message_end" and .message.role == "assistant")] | last | [.message.content[]? | select(.type == "text") | .text] | join("")' "$S" 2>/dev/null)
echo "answer ($(cat "$PO/session.seconds" 2>/dev/null) s): ${answer:-<none>}"
call_ok() {
  jq -se '
    [.[] | select(.type == "tool_execution_start" and (.toolName | test("stock_level$"))) | {id: .toolCallId, args}] as $starts
    | [.[] | select(.type == "tool_execution_end" and (.toolName | test("stock_level$")) and (.isError | not))] as $ends
    | any($ends[]; . as $e
        | ([.result.content[]? | .text // empty] | join("") | (try fromjson catch {})) as $r
        | ($starts[] | select(.id == $e.toolCallId) | .args) as $a
        | ($a.sku == "OG-1138") and (($a.warehouse // "") | ascii_downcase) == "north"
          and $r.units == 42 and $r.ref == "inv-7f3a9c")' "$S" >/dev/null 2>&1
}
name="pi's session calls stock_level(OG-1138, north) and gets units 42, ref inv-7f3a9c"
if call_ok; then
  pass $G "$name"
elif [[ $SMALL_MODEL == 1 ]]; then
  blocked best-effort $G "$name" "SMALL_MODEL=1 (Qwen2.5-0.5B): $(jq -rs '[.[] | select(.type == "tool_execution_start") | .toolName] | join(",")' "$S" 2>/dev/null) ${answer:0:120}"
else
  fail $G "$name" "tool calls: $(jq -rs '[.[] | select(.type == "tool_execution_start") | .toolName] | join(",")' "$S" 2>/dev/null); answer: ${answer:0:120}"
fi

# --- 5. the offline settings -------------------------------------------------------------
env=$(podman image inspect "$IMG" --format '{{json .Config.Env}}')
jq -r '.[] | select(startswith("PI_"))' <<<"$env"
check $G "the pi image sets PI_OFFLINE=1, PI_SKIP_VERSION_CHECK=1 and PI_TELEMETRY=0" "$env" \
  jq -e 'index("PI_OFFLINE=1") and index("PI_SKIP_VERSION_CHECK=1") and index("PI_TELEMETRY=0")' <<<"$env"

# --- shown, not gated --------------------------------------------------------------------
echo "best-effort, not gated: the write-then-run coding task: $(jq -c . "$PO/coding.json" 2>/dev/null || echo 'not run')"
