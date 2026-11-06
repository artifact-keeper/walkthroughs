#!/usr/bin/env bash
# Step 6 (best-effort): Claude Code on the site network.
#   0. a clean npm install of Claude Code in a fresh node container, from npm-remote alone;
#   1. the marketplace and the plugin from Artifact Keeper: claude plugin marketplace add (the
#      token-in-path URL of the plugins Remote), claude plugin install offgrid-ops@plugins;
#   2. one prompt answered by the local model through llama-server's Anthropic-compatible
#      Messages API (ANTHROPIC_BASE_URL), with a one-line system prompt and no tools. A 1.5B
#      model behind Claude Code's full harness is slow and does not follow it; this shows the
#      wiring, not a coding assistant.
# Results in out/claude/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $(phase) == site ]] || { echo "claude.sh: run make disconnect first" >&2; exit 1; }
CO="$ROOT/out/claude"; mkdir -p "$CO"
podman image exists localhost/ak-offgrid/claude:latest || { echo "claude.sh: no Claude Code image (make seed builds it)"; exit 0; }
H="$ROOT/out/homes/claude"; rm -rf "$H"; mkdir -p "$H"
crun() {
  AK_TOKEN=$(tok developer) podman run --rm -i --network "$NET" --userns keep-id:uid=1001,gid=1001 --user 1001:1001 \
    -e AK_TOKEN -e HOME=/home/dev -v "$H:/home/dev:z" \
    -e ANTHROPIC_BASE_URL="http://$LLAMA:8080" -e ANTHROPIC_AUTH_TOKEN=local -e ANTHROPIC_MODEL=local \
    -e ANTHROPIC_SMALL_FAST_MODEL=local -e API_TIMEOUT_MS=900000 \
    localhost/ak-offgrid/claude:latest "$@"
}

say "0. a clean install of Claude Code from npm-remote, on the site"
node_ref=$(manifest '.image[] | select(.name == "node") | .ref')
cc=$(manifest '.npm[] | select(.name == "@anthropic-ai/claude-code") | .version')
AK_TOKEN=$(tok developer) podman run --rm -i --network "$NET" -e AK_TOKEN -e CC="$cc" \
  -v "$CA:/ca.crt:ro,z" "$P/oci-dockerhub/$node_ref" bash -euc '
  export NODE_EXTRA_CA_CERTS=/ca.crt
  r=ak.internal/npm/npm-remote/
  printf "registry=https://%s\n//%s:_authToken=%s\n" "$r" "$r" "$AK_TOKEN" > /tmp/npmrc
  t=$(date +%s)
  npm install -g --userconfig /tmp/npmrc --no-fund --no-audit "@anthropic-ai/claude-code@$CC" 2>&1 | tail -1
  echo "claude --version: $(claude --version) ($(( $(date +%s) - t )) s)"' 2>&1 | tee "$CO/npm-install.txt"

say "1. the marketplace and the plugin, from the plugins Remote"
crun bash -c '
  set -euo pipefail
  url="https://ak.internal/agentplugins/t/$AK_TOKEN/plugins/claude-marketplace.json"
  echo "\$ claude plugin marketplace add https://ak.internal/agentplugins/t/<token>/plugins/claude-marketplace.json --json"
  claude plugin marketplace add "$url" --json 2>&1 | sed "s/$AK_TOKEN/<token>/g"
  echo "\$ claude plugin install offgrid-ops@plugins --json"
  claude plugin install offgrid-ops@plugins --json 2>&1
  echo "\$ claude plugin list --json"
  claude plugin list --json' 2>&1 | tee "$CO/plugin.txt"

say "2. best-effort: one prompt through the local model (Anthropic Messages API on llama-server)"
# Claude Code's own system prompt and tool definitions are tens of thousands of tokens; a 1.5B
# model on a CPU takes minutes to read them and then does not follow the instruction (in the
# reference run it echoed part of the prompt back after 300 s). With a one-line system prompt
# and no tools the same wiring answers in seconds. CLAUDE_FULL=1 also runs the default session.
t=$SECONDS
crun timeout 900 claude -p 'Reply with exactly the word OFFGRID and nothing else.' \
  --system-prompt 'You are a terse assistant. Follow the instruction exactly.' --tools '' \
  --output-format json --max-turns 1 > "$CO/session.json" 2> "$CO/session.err" || true
echo "  minimal prompt, no tools, $((SECONDS - t)) s: $(jq -c '{is_error, result: ((.result // "")[0:200]), duration_ms}' "$CO/session.json" 2>/dev/null || tail -c 300 "$CO/session.err")"
if [[ ${CLAUDE_FULL:-0} == 1 ]]; then
  t=$SECONDS
  crun timeout 900 claude -p 'Reply with exactly the word OFFGRID and nothing else.' --output-format json \
    --max-turns 1 > "$CO/session-full.json" 2> "$CO/session-full.err" || true
  echo "  default system prompt and tools, $((SECONDS - t)) s: $(jq -c '{is_error, result: ((.result // "")[0:120]), duration_ms}' "$CO/session-full.json" 2>/dev/null || tail -c 300 "$CO/session-full.err")"
fi
