#!/usr/bin/env bash
# G5 Claude Code (best-effort step): on the site network, Claude Code adds the plugins
# Remote as a marketplace and installs offgrid-ops from it; then one prompt goes to the local
# model through llama-server's Anthropic-compatible API. The install is checked; the session
# is best-effort (BLOCKED(best-effort) when the small model does not answer as asked).
# Reads what flows/claude.sh left in out/claude/ (make claude).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_site
G=G5
CO="$ROOT/out/claude"
if ! podman image exists localhost/ak-offgrid/claude:latest; then
  blocked best-effort $G "Claude Code installs offgrid-ops from the plugins Remote, offline" "no Claude Code image (its build failed while seeding; out/flows/claude-build.log)"
  exit 0
fi
grep -E '"(id|name|version|success)"' "$CO/plugin.txt" | head -8
check $G "Claude Code installs offgrid-ops from the plugins Remote, offline" "$(tail -c 300 "$CO/plugin.txt")" \
  bash -c "sed -n '/claude plugin list --json/,\$p' '$CO/plugin.txt' | tail -n +2 | jq -e 'any(.[]; .id == \"offgrid-ops@plugins\")' >/dev/null"
r=$(jq -r '.result // empty' "$CO/session.json" 2>/dev/null)
echo "session: $(jq -c '{is_error, result: ((.result // "")[0:120]), duration_ms}' "$CO/session.json" 2>/dev/null || tail -c 200 "$CO/session.err")"
if [[ $r == *OFFGRID* ]]; then
  pass $G "best-effort: Claude Code gets the asked-for answer from the local model (ANTHROPIC_BASE_URL -> llama-server; minimal system prompt, no tools)"
else
  blocked best-effort $G "best-effort: Claude Code gets the asked-for answer from the local model (ANTHROPIC_BASE_URL -> llama-server; minimal system prompt, no tools)" \
    "$(jq -c '{is_error, result: ((.result // "")[0:100])}' "$CO/session.json" 2>/dev/null || tail -c 160 "$CO/session.err" | tr '\n' ' ')"
fi
