#!/usr/bin/env bash
# G8 ak harness installs, in a fresh home and a scratch repository with acme-g8 1.0.0 and
# 1.1.0 (manifests for Claude Code, Cursor and Codex): every harness location is written
# with a correct .ak/plugin-info.json, the local marketplaces list it, update status moves
# behind -> current -> ahead, and uninstall removes the marketplace entry. The agents' own
# CLIs (claude, codex, copilot) see the installs. Using them in a session needs an account.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G8; R=agent-plugins-gate-g8; P=acme-g8; H="$ROOT/out/homes/g8"
fresh_repo "$R" || exit 1; rm -rf "$H"
for v in 1.0.0 1.1.0; do
  d="$G_TMP/g8-$v"; claude_dir "$d" $P $v
  for m in .cursor-plugin .codex-plugin; do mkdir -p "$d/$m"; cp "$d/.claude-plugin/plugin.json" "$d/$m/"; done
  python3 "$MKZIP" "$G_TMP/g8-$v.zip" "$d"; c=$(put_zip "$R" $P $v "$G_TMP/g8-$v.zip"); echo "publish $P $v -> $c"
done
sha10=$(sha256sum "$G_TMP/g8-1.0.0.zip" | cut -d' ' -f1)
ak() { AK_FORMAT=json "$RUN" -h g8 -t admin -- ak agent plugins "$@" 2>>"$G_TMP/g8-stderr.txt"; }

ak install $P --repo $R --harness claude,cursor,codex,vscode --version 1.0.0 > "$G_TMP/g8-install.json"; rc=$?
jq -c '.[] | {harness, version, path, ran, to_run}' "$G_TMP/g8-install.json"
check $G "install for claude, cursor, codex and vscode (rc 0)" "rc $rc" test $rc = 0
declare -A loc=([claude]=".claude/plugins/local/ak/$R/$P" [cursor]=".cursor/plugins/local/$P"
                [codex]=".agents/plugins/local/ak/$R/$P" [vscode]=".copilot/installed-plugins/ak-$R/$P")
bad=0
for h in claude cursor codex vscode; do
  f="$H/${loc[$h]}/.ak/plugin-info.json"
  if [[ -f $f ]] && jq -e --arg h $h --arg r $R --arg s $P --arg sha "$sha10" \
       '.harness == $h and .repo == $r and .slug == $s and .version == "1.0.0" and .sha256 == $sha and .instance == "https://ak.internal" and (.installed_at | length > 0)' "$f" >/dev/null; then
    echo "ok   $h: ~/${loc[$h]}"; else echo "BAD  $h: $f $(cat "$f" 2>/dev/null)"; bad=1; fi
done
check $G "every harness location written, .ak/plugin-info.json correct (instance, repo, slug, version, sha256, harness)" "see log" test $bad = 0
check $G "Claude Code local marketplace ak-$R lists $P" "see log" \
  jq -e --arg p $P 'any(.plugins[]; .name == $p and .source == "./\($p)")' "$H/.claude/plugins/local/ak/$R/.claude-plugin/marketplace.json"
check $G "Codex local marketplace ak-$R lists $P as a local source" "see log" \
  jq -e --arg p $P 'any(.plugins[]; .name == $p and .source.source == "local")' "$H/.agents/plugins/local/ak/$R/.agents/plugins/marketplace.json"

"$RUN" -h g8 -- bash -c '
  claude plugin list --json > /out/gates/tmp/g8-claude.json
  codex plugin marketplace list --json > /out/gates/tmp/g8-codex-mp.json 2>/dev/null
  copilot plugin list --json > /out/gates/tmp/g8-copilot.json' 2>/dev/null
check $G "Claude Code lists $P@ak-$R (ak ran claude plugin marketplace add and install)" "see log" \
  jq -e --arg id "$P@ak-$R" 'any(.[]; .id == $id)' "$G_TMP/g8-claude.json"
check $G "Codex lists the marketplace ak-$R (ak ran codex plugin marketplace add)" "see log" \
  jq -e --arg n "ak-$R" 'any(.marketplaces[]; .name == $n)' "$G_TMP/g8-codex-mp.json"
check $G "Copilot lists $P (ak ran copilot plugin install)" "see log" \
  jq -e --arg p $P 'any(.[]; .name == $p)' "$G_TMP/g8-copilot.json"

st() { ak list --check-updates | jq -r --arg p $P '[.[] | select(.slug == $p) | "\(.harness)=\(.status)"] | sort | join(",")'; }
s=$(st); echo "list --check-updates: $s"
check $G "with 1.1.0 on the server every install is behind" "$s" test "$s" = "claude=behind,codex=behind,cursor=behind,vscode=behind"
ak update --all > "$G_TMP/g8-update.json"; jq -c '.[] | {harness, from, to, status}' "$G_TMP/g8-update.json"
s=$(st); echo "after update --all: $s"
check $G "after update --all every install is current" "$s" test "$s" = "claude=current,codex=current,cursor=current,vscode=current"
c=$(http DELETE "$U/api/v1/repositories/$R/artifacts/$P/1.1.0/$P-1.1.0.zip" admin); echo "server: DELETE $P 1.1.0 -> $c"
s=$(st); echo "after the server drops 1.1.0: $s"
check $G "when the server's newest is older than the install, it is ahead" "$s" test "$s" = "claude=ahead,codex=ahead,cursor=ahead,vscode=ahead"

ak uninstall $P --harness codex,claude > "$G_TMP/g8-uninstall.json"; rc=$?
jq -c '.[] | {harness, path, hints}' "$G_TMP/g8-uninstall.json" 2>/dev/null
gone=1
for h in claude codex; do [[ -e "$H/${loc[$h]}" ]] && gone=0; done
jq -e --arg p $P 'any(.plugins[]; .name == $p)' "$H/.claude/plugins/local/ak/$R/.claude-plugin/marketplace.json" >/dev/null && gone=0
jq -e --arg p $P 'any(.plugins[]; .name == $p)' "$H/.agents/plugins/local/ak/$R/.agents/plugins/marketplace.json" >/dev/null && gone=0
check $G "uninstall removes the directories and the marketplace entries ak wrote" "rc $rc" bash -c "[[ $rc == 0 && $gone == 1 ]]"
blocked account $G "the agents use the installed plugin in a session" \
  "after logging in (codex login; copilot login; cursor-agent login, or reload a Cursor window) in out/homes/g8, ask each agent for the fixture skill 'check'"
