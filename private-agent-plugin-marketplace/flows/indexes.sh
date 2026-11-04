#!/usr/bin/env bash
# Fetch the five marketplace documents and one plugin's index.json with the developer's
# read token, save them pretty-printed under out/indexes/, and summarise what each lists.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
D="$ROOT/out/indexes"; mkdir -p "$D"
for doc in marketplace claude-marketplace cursor-marketplace codex-marketplace vscode-marketplace; do
  akcurl -fsS -H "Authorization: Bearer $(tok developer)" "$U/agentplugins/$REPO/$doc.json" | jq . > "$D/$doc.json"
  printf '%-26s name=%-14s plugins: %s\n' "$doc.json" "$(jq -r .name "$D/$doc.json")" \
    "$(jq -r '[.plugins[] | "\(.name)@\(.version)"] | join(", ")' "$D/$doc.json")"
done
akcurl -fsS -H "Authorization: Bearer $(tok developer)" "$U/agentplugins/$REPO/acme-review/index.json" | jq . > "$D/acme-review-index.json"
say "claude-marketplace.json (what Claude Code reads)"
cat "$D/claude-marketplace.json"
say "marketplace.json, one entry (Artifact Keeper's data sits under metadata)"
jq '.plugins[] | select(.name == "acme-standards")' "$D/marketplace.json"
say "acme-review/index.json (what ak reads)"
cat "$D/acme-review-index.json"
echo; echo "saved in out/indexes/"
