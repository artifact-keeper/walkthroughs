#!/usr/bin/env bash
# G4 Claude Code end to end, in a fresh home: the private marketplace registered through
# settings.json (Authorization header) and registered by a session start, acme-review and acme-standards installed, and the
# installed files are exactly the published zip's (skills, commands, agents, hooks). None
# of this needs an Anthropic account. Using the plugin in a session does: that check is
# BLOCKED(account) with the command to run after `claude /login`.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G4; H="$ROOT/out/homes/g4"; rm -rf "$H"
latest=$(akcurl -fsS -H "Authorization: Bearer $(tok developer)" "$U/agentplugins/$REPO/acme-review/index.json" | jq -r .latest)
echo "acme-review latest in $REPO: $latest"
"$RUN" -h g4 -t developer -- bash -c '
  mkdir -p ~/.claude
  jq -n --arg t "$AK_TOKEN" "{extraKnownMarketplaces: {\"agent-plugins\": {source: {source: \"url\",
        url: \"https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json\",
        headers: {Authorization: (\"Bearer \" + \$t)}}}}}" > ~/.claude/settings.json
  claude plugin marketplace list --json > /out/gates/tmp/g4-mp-before.json
  timeout 120 claude -p hello </dev/null > /out/gates/tmp/g4-session.txt 2>&1; echo "session_rc=$?"
  claude plugin marketplace list --json > /out/gates/tmp/g4-mp-list.json; echo "mp_list_rc=$?"
  claude plugin install acme-review@agent-plugins --json > /out/gates/tmp/g4-install-review.json; echo "install_review_rc=$?"
  claude plugin install acme-standards@agent-plugins --json > /out/gates/tmp/g4-install-standards.json; echo "install_standards_rc=$?"
  claude plugin list --json > /out/gates/tmp/g4-list.json; echo "list_rc=$?"
  claude plugin details acme-review@agent-plugins > /out/gates/tmp/g4-details.txt 2>&1; echo "details_rc=$?"' | tee "$G_TMP/g4-rc.txt"
rc() { grep "^$1=" "$G_TMP/g4-rc.txt" | cut -d= -f2; }
echo "marketplaces before a session: $(jq -c '[.[].name]' "$G_TMP/g4-mp-before.json"); session: $(head -1 "$G_TMP/g4-session.txt") (rc $(rc session_rc))"
cat "$G_TMP"/g4-install-*.json 2>/dev/null; echo
jq -c '.[] | {name, source, url}' "$G_TMP/g4-mp-list.json"
check $G "the settings.json marketplace (with its header) is registered by a session start, even one that stops at the login" "see log" \
  bash -c "jq -e 'length == 0' '$G_TMP/g4-mp-before.json' >/dev/null && jq -e 'any(.[]; .name == \"agent-plugins\" and .url == \"https://ak.internal/agentplugins/agent-plugins/claude-marketplace.json\")' '$G_TMP/g4-mp-list.json' >/dev/null"
check $G "claude plugin install acme-review@agent-plugins (rc 0, outcome ok)" "rc $(rc install_review_rc)" \
  bash -c "[[ $(rc install_review_rc) == 0 ]] && jq -e '.outcome == \"ok\"' '$G_TMP/g4-install-review.json' >/dev/null"
jq -c '.[] | {id, version, enabled}' "$G_TMP/g4-list.json"
check $G "claude plugin list: acme-review@agent-plugins enabled at the registry's latest ($latest)" "see log" \
  jq -e --arg v "$latest" 'any(.[]; .id == "acme-review@agent-plugins" and .version == $v and .enabled)' "$G_TMP/g4-list.json"

C="$H/.claude/plugins/cache/agent-plugins/acme-review/$latest"
missing=0; for f in .claude-plugin/plugin.json skills/review/SKILL.md commands/checklist.md agents/reviewer.md hooks/hooks.json; do
  [[ -f "$C/$f" ]] && echo "present: $f" || { echo "missing: $f"; missing=1; }; done
check $G "skill, command, agent and hook are in Claude Code's plugin cache" "see log" test $missing = 0
rm -rf "$G_TMP/g4-zip"; mkdir -p "$G_TMP/g4-zip"
akcurl -fsS -H "Authorization: Bearer $(tok developer)" "$U/agentplugins/$REPO/acme-review/$latest/acme-review-$latest.zip" -o "$G_TMP/g4.zip"
(cd "$G_TMP/g4-zip" && unzip -q "$G_TMP/g4.zip")
d=$(diff -r -x .in_use "$G_TMP/g4-zip" "$C" 2>&1); echo "${d:-cache identical to the published zip}"
check $G "the installed files are byte-identical to the published zip" "differs" test -z "$d"
check $G "the installed manifest's version equals the registry version" "see log" \
  jq -e --arg v "$latest" '.version == $v' "$C/.claude-plugin/plugin.json"
S="$H/.claude/plugins/cache/agent-plugins/acme-standards"
ls "$S"/*/skills 2>/dev/null
check $G "Agent Plugins Standard plugin installs into Claude Code with its skills" "rc $(rc install_standards_rc)" \
  bash -c "[[ $(rc install_standards_rc) == 0 ]] && ls '$S'/*/skills/acme-style/SKILL.md >/dev/null 2>&1"
head -20 "$G_TMP/g4-details.txt"
check $G "claude plugin details shows the component inventory without an account" "rc $(rc details_rc)" test "$(rc details_rc)" = 0
blocked account $G "a signed-in Claude Code session uses the plugin" \
  "after 'claude /login' in out/homes/g4, run: claude -p '/acme-review:checklist' (and ask for a review to load the review skill)"
