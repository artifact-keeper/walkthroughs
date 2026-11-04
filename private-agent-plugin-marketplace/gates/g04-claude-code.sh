#!/usr/bin/env bash
# G4 Claude Code end to end, in a fresh home: the private marketplace registered through
# settings.json (Authorization header) and registered by a session start, acme-review and acme-standards installed, and the
# installed files are exactly the published zip's (skills, commands, agents, hooks). None
# of this needs an Anthropic account. Using the plugin in a session does: that check runs when
# CLAUDE_CODE_OAUTH_TOKEN is set, and is BLOCKED(account) otherwise.
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
# With a Claude Code session token in the environment (CLAUDE_CODE_OAUTH_TOKEN, from
# `claude setup-token`; the nightly runner passes it from ~/.config/ak-e2e/), start a real
# session in the G4 home and run the plugin's command. Cheap and bounded: haiku, no tools, two
# turns, a budget cap, nothing persisted. The checks read the stream-json events, not the
# model's prose: the init event's command, agent and skill lists, the SessionStart hook's
# response, and the result event.
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  SJ="$G_TMP/g4-session.jsonl"
  "$RUN" -c -h g4 -- bash -c 'cd /tmp && timeout 300 claude -p "/acme-review:checklist" --model haiku \
      --max-turns 2 --max-budget-usd 0.25 --tools "" --no-session-persistence \
      --output-format stream-json --verbose </dev/null' > "$SJ" 2> "$G_TMP/g4-session.err"
  src=$?
  ev() { jq -c "$1" "$SJ" 2>/dev/null | head -1; }
  echo "session rc $src"
  echo "init: $(ev 'select(.type == "system" and .subtype == "init") | {model, claude_code_version,
    plugins: [.plugins[] | select(.name | startswith("acme")) | {name, version}],
    commands: [.slash_commands[] | select(startswith("acme"))], agents: [.agents[] | select(startswith("acme"))],
    skills: [.skills[] | select(startswith("acme"))], mcp_servers}')"
  echo "hook: $(ev 'select(.type == "system" and .subtype == "hook_response") | {hook_event, exit_code, outcome, stdout}')"
  echo "result: $(ev 'select(.type == "result") | {subtype, is_error, num_turns, api_error_status, total_cost_usd}')"
  init_has() { # init_has FIELD NAME...
    local f=$1 n; shift
    for n in "$@"; do
      jq -se --arg f "$f" --arg n "$n" 'any(.[]; .type == "system" and .subtype == "init" and any(.[$f][]?; . == $n))' \
        "$SJ" >/dev/null || { echo "init.$f has no $n"; return 1; }
    done
  }
  # the hook's expected output is the text its command echoes, read from the published hooks.json
  hook_text=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ROOT/plugins/acme-review/hooks/hooks.json" | sed -E "s/^echo '(.*)'$/\1/")
  hook_ran() {
    jq -se --arg t "$hook_text" 'any(.[]; .type == "system" and .subtype == "hook_response" and .hook_event == "SessionStart"
      and .exit_code == 0 and (.stdout | rtrimstr("\n")) == $t)' "$SJ" >/dev/null
  }
  finished_ok() {
    [[ $src == 0 ]] && jq -se 'any(.[]; .type == "result" and .is_error == false and .subtype == "success")' "$SJ" >/dev/null
  }
  loads_latest() {
    jq -se --arg v "$latest" 'any(.[]; .type == "system" and .subtype == "init"
      and any(.plugins[]?; .name == "acme-review" and .version == $v))' "$SJ" >/dev/null
  }
  check $G "signed-in session: the init event loads acme-review at the registry's latest ($latest)" "see log" loads_latest
  check $G "signed-in session: the init event lists the plugin command acme-review:checklist" "see log" \
    init_has slash_commands acme-review:checklist
  check $G "signed-in session: the init event lists the plugin agent acme-review:reviewer" "see log" \
    init_has agents acme-review:reviewer
  check $G "signed-in session: the init event lists the acme-standards skills" "see log" \
    init_has skills acme-standards:acme-style acme-standards:acme-secure-defaults
  check $G "signed-in session: the plugin's SessionStart hook ran (exit 0, its own output)" "see log" hook_ran
  check $G "signed-in session: /acme-review:checklist completes without an error" \
    "rc $src, see out/gates/tmp/g4-session.*" finished_ok
else
  blocked account $G "signed-in session: the plugin's command, agent, skills and hook load and run" \
    "set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) and rerun, or after 'claude /login' in out/homes/g4 run: claude -p '/acme-review:checklist'"
fi
