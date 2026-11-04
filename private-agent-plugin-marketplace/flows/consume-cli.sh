#!/usr/bin/env bash
# Cursor, Codex and GitHub Copilot accept no hosted marketplace URL, so the developer
# installs with the ak CLI, which reads <name>/index.json, checks the zip's SHA-256 and
# unpacks it where each agent looks. Then each agent's own CLI is asked what it sees.
# Home: out/homes/workstation (kept for make update).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rm -rf "$ROOT/out/homes/workstation"
"$RUN" -h workstation -t developer -- bash -c '
  set -uo pipefail
  run() { echo "\$ $*"; "$@"; echo; }
  run ak agent plugins install acme-release-notes --repo agent-plugins --harness cursor,codex,vscode
  run ak agent plugins install acme-standards --repo agent-plugins --harness cursor,codex,vscode
  # Claude Code layout plugins also load in Copilot: ak warns, and installs.
  run ak agent plugins install acme-review --repo agent-plugins --harness vscode
  run ak agent plugins list
  echo "--- what each agent sees"
  echo "\$ find ~/.cursor/plugins/local -maxdepth 2   (Cursor loads this directory; its CLI has no local listing)"
  find ~/.cursor/plugins/local -maxdepth 2 | sort; echo
  run codex plugin marketplace list
  run codex plugin add acme-release-notes@ak-agent-plugins
  run codex plugin list
  run copilot plugin list
  echo "--- one .ak/plugin-info.json"
  cat ~/.cursor/plugins/local/acme-standards/.ak/plugin-info.json' 2>&1 | grep -v '^WARNING: proceeding, even though'
