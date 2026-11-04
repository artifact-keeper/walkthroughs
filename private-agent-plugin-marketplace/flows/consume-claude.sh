#!/usr/bin/env bash
# Claude Code installs from the registry itself, with no extra tooling, three ways. Each
# runs in its own throwaway home under out/homes/:
#   claude-settings  private repository, settings route: extraKnownMarketplaces in
#                    ~/.claude/settings.json with an Authorization header (what managed
#                    settings would push), a session start to register it, then
#                    claude plugin install
#   claude-token     private repository, token-in-path route: claude plugin marketplace add
#                    https://ak.internal/agentplugins/t/<token>/agent-plugins/claude-marketplace.json
#   claude-public    public repository, plain URL, no credentials
# The developer's read-only repository token is the credential in the first two.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for h in claude-settings claude-token claude-public; do rm -rf "$ROOT/out/homes/$h"; done

say "1. settings route (private repository, header from settings.json)"
"$RUN" -h claude-settings -t developer -- bash -c '
  set -euo pipefail
  mkdir -p ~/.claude
  jq -n --arg t "$AK_TOKEN" "{extraKnownMarketplaces: {\"agent-plugins\": {source: {source: \"url\",
        url: \"https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json\",
        headers: {Authorization: (\"Bearer \" + \$t)}}}}}" > ~/.claude/settings.json
  echo "~/.claude/settings.json:"; sed "s/$AK_TOKEN/<developer token>/" ~/.claude/settings.json
  # Claude Code registers the marketplaces declared in settings when a session starts. With
  # no account the session stops at "Not logged in", after that step; a signed-in developer
  # gets the same on their first start.
  echo "\$ claude -p hello    (starts a session: registers the marketplace, then stops at the login)"
  claude -p hello </dev/null 2>&1 | tail -1 || true
  echo "\$ claude plugin marketplace list --json"
  claude plugin marketplace list --json
  echo "\$ claude plugin install acme-review@agent-plugins --json"
  claude plugin install acme-review@agent-plugins --json
  echo "\$ claude plugin install acme-standards@agent-plugins --json"
  claude plugin install acme-standards@agent-plugins --json
  echo "\$ claude plugin list --json"
  claude plugin list --json | jq -c ".[] | {id, version, enabled}"
  echo "installed files:"; (cd ~/.claude/plugins/cache/agent-plugins && find . -type f ! -name .in_use | sort)'

say "2. token-in-path route (private repository, no settings edit)"
"$RUN" -h claude-token -t developer -- bash -c '
  set -euo pipefail
  url="https://ak.internal/agentplugins/t/$AK_TOKEN/agent-plugins/claude-marketplace.json"
  echo "\$ claude plugin marketplace add https://ak.internal/agentplugins/t/<developer token>/agent-plugins/claude-marketplace.json --json"
  claude plugin marketplace add "$url" --json | sed "s/$AK_TOKEN/<developer token>/g"
  echo "\$ claude plugin install acme-release-notes@agent-plugins --json"
  claude plugin install acme-release-notes@agent-plugins --json
  claude plugin list --json | jq -c ".[] | {id, version, enabled}"
  echo "where the token now sits in plain text (files under ~/.claude, occurrences):"
  grep -rcF "$AK_TOKEN" ~/.claude | grep -v ":0$" | sed "s#^/home/dev/#  ~/#"'

say "3. public repository (no credentials)"
"$RUN" -h claude-public -- bash -c '
  set -euo pipefail
  echo "\$ claude plugin marketplace add https://ak.internal/agentplugins/agent-plugins-public/claude-marketplace.json --json"
  claude plugin marketplace add https://ak.internal/agentplugins/agent-plugins-public/claude-marketplace.json --json
  echo "\$ claude plugin install acme-release-notes@agent-plugins-public --json"
  claude plugin install acme-release-notes@agent-plugins-public --json
  claude plugin list --json | jq -c ".[] | {id, version, enabled}"'
