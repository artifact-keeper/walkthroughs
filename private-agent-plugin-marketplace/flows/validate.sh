#!/usr/bin/env bash
# Validate the three plugins before publishing them: `claude plugin validate` (Claude
# Code's own checker, no account needed) on each, and the Agent Plugins Standard rules on
# acme-standards' root plugin.json ($schema, name pattern, no unknown top-level keys).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
"$RUN" -- bash -c '
  rc=0
  for p in acme-review acme-standards acme-release-notes; do
    echo "\$ claude plugin validate /plugins/$p"
    claude plugin validate "/plugins/$p" || rc=1
    echo
  done
  echo "\$ (Agent Plugins Standard 1.0.0 rules) /plugins/acme-standards/plugin.json"
  jq -e '"'"'
    .["$schema"] == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
    and (.name | test("^(?!.*(?:--|\\.\\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"))
    and ((keys - ["$schema","name","version","description","author","homepage","repository","license","keywords","extensions"]) == [])
  '"'"' /plugins/acme-standards/plugin.json >/dev/null && echo "ok: schema, name, keys" || { echo "FAILED"; rc=1; }
  exit $rc'
