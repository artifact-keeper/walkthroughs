#!/usr/bin/env bash
# Ship an update: acme-review 1.1.0 adds an item to the checklist. CI publishes it with
# --version 1.1.0 (ak writes the version into the manifest inside the upload; the plugin
# directory still says 1.0.0). Then Claude Code (home claude-settings) and the ak installs
# (home workstation, from make consume-cli) pick it up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W="$ROOT/out/work/acme-review-1.1.0"
rm -rf "$W"; mkdir -p "$(dirname "$W")"; cp -r "$ROOT/plugins/acme-review" "$W"
echo '- [ ] New endpoints log the request ID and the caller, and nothing secret' >> "$W/commands/checklist.md"

say "publish acme-review 1.1.0"
if published "$REPO" acme-review 1.1.0; then echo "  acme-review 1.1.0 is already in $REPO: skipped"; else
  "$RUN" -t ci -- ak agent plugins publish /out/work/acme-review-1.1.0 --repo "$REPO" --version 1.1.0 | tee "$FOUT/publish-acme-review-1.1.0.txt"
fi
wait_listed "$REPO" acme-review 1.1.0

say "Claude Code (settings route home): refresh the marketplace, update the plugin"
"$RUN" -h claude-settings -- bash -c '
  set -euo pipefail
  echo "\$ claude plugin marketplace update agent-plugins"; claude plugin marketplace update agent-plugins
  echo "\$ claude plugin update acme-review@agent-plugins --json"; claude plugin update acme-review@agent-plugins --json
  claude plugin list --json | jq -c ".[] | {id, version}"
  echo "the new checklist item:"; tail -1 ~/.claude/plugins/cache/agent-plugins/acme-review/1.1.0/commands/checklist.md'

say "ak installs (workstation home): what is behind, then update everything"
"$RUN" -h workstation -t developer -- bash -c '
  echo "\$ ak agent plugins list --check-updates"; ak agent plugins list --check-updates
  echo "\$ ak agent plugins update --all"; ak agent plugins update --all
  echo "\$ ak agent plugins list --check-updates"; ak agent plugins list --check-updates' 2>&1 | grep -v '^WARNING: proceeding, even though'
