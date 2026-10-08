#!/usr/bin/env bash
# S6 allowlist-from-a-pull-request: the CI loop, with scenarios/allowlist-ci.sh as the job.
#   PR 1  a copy of project/ adds colorama: lock against the unfiltered twin (scn-virtual-ci),
#         allowlist from the new lock, then colorama installs through conda-virtual at once and
#         through Nexus once Nexus has revalidated (metadataMaxAge)
#   PR 2  the same copy swaps colorama for toolz: colorama is "not found" through conda-virtual
#         at once and through Nexus after the TTL; toolz installs. Nexus keeps the colorama
#         file it cached in PR 1 (cached files are not revoked; recorded, it is Nexus's rule)
# Restores the allowlist exactly as found, also on failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
scn_begin S6 allowlist-from-a-pull-request "a dependency change goes through CI to the allowlist"
TTL_MIN=$(nxapi GET /v1/repositories/conda/proxy/ak-virtual | jq -r .proxy.metadataMaxAge)
ADD2=${ADD2:-toolz}
on_exit 'echo "   $(nx_invalidate ak-virtual)"'
al_save
P="$WORK/s6/pr"; project_copy "$P"
"$ROOT/allowlist/from-lock.sh" --list "$ROOT/project/pixi.lock" | cut -f1 | grep -qx "$OUTSIDE" && { fail "setup" "$OUTSIDE already in project/pixi.lock"; exit 1; }
nxcnt() { # NAME -> records in Nexus's ak-virtual noarch index (conditional poll until it changes is done by the caller)
  nxget ak-virtual noarch/repodata.json.bz2 >/dev/null; bzip2 -dc "$WORK/last.body" | jq --arg n "$1" '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name == $n)] | length'; }
wait_nexus() { # NAME want(present|absent) -> seconds; Nexus revalidates by itself after metadataMaxAge
  local t0=$SECONDS n
  while (( SECONDS - t0 < TTL_MIN * 60 * 3 + 60 )); do
    n=$(nxcnt "$1"); { [[ $2 == present && $n -gt 0 ]] || [[ $2 == absent && $n == 0 ]]; } && { echo $((SECONDS - t0)); return 0; }
    sleep 10; done; echo $((SECONDS - t0)); return 1; }

# baseline: the allowlist in force is project/pixi.lock's, and Nexus already serves it
note "baseline: allowlist from project/pixi.lock, Nexus caught up"
ev "baseline allowlist: $(al_on_from_lock)"
echo "   $(nx_invalidate ak-virtual)"
n=$(nxcnt "$OUTSIDE"); ev "baseline: $OUTSIDE records through Nexus: $n"
[[ $n == 0 ]] || { fail "baseline" "$OUTSIDE still listed through Nexus"; exit 1; }
nx_purge ak-virtual "/$OUTSIDE-" >/dev/null

# PR 1: add colorama
note "PR 1: add $OUTSIDE"
sed -i "s/^python = \"3.12.\*\"$/&\n$OUTSIDE = \"*\"/" "$P/pixi.toml"
ev "PR 1 diff: $(diff "$ROOT/project/pixi.toml" "$P/pixi.toml" | grep '^[<>]' | tr '\n' ' ')"
t_al=$SECONDS
out=$(CACHE_VOLUME=scn-s6-ci1 "$SCN_DIR/allowlist-ci.sh" all "$P" 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
ev "allowlist-ci.sh all (PR 1): exit $rc; $(grep -E 'apply:|^allowlist-ci:   [+-]' <<<"$out" | tr '\n' ' ')"
lk=$(lock_has "$P" "$OUTSIDE")
[[ $rc == 0 && $lk == https://ak.internal/conda/conda-virtual/* ]]; check $? "PR 1: allowlist-ci.sh locks $OUTSIDE against the unfiltered twin (lock URL ${lk##*/conda/}), sets the allowlist, and pixi install --locked through conda-virtual passes" "exit $rc: $(tail -2 <<<"$out" | tr '\n' ' ')"
r=$(akget "$(consumer_tok)" "conda/conda-virtual/$OUTSIDE_FILE"); ev "AK conda-virtual GET $OUTSIDE_FILE: HTTP $r"
s=$(wait_nexus "$OUTSIDE" present); rcw=$?
ev "Nexus's ak-virtual index lists $OUTSIDE $s s after the wait began ($((SECONDS - t_al)) s after allowlist-ci.sh started; metadataMaxAge ${TTL_MIN} min)"
D="$WORK/s6/via-nexus"; rm -rf "$D"; mkdir -p "$D"; cp "$P/pixi.toml" "$P/pixi.lock" "$D/"
px nexus "$D" new:scn-s6-nx1 install --locked
ev "pixi install --locked through Nexus after the TTL: exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $rcw == 0 && $PX_RC == 0 ]]; check $? "PR 1: through Nexus, after Nexus revalidated (${s} s), the new lock installs including $OUTSIDE" "index wait rc $rcw; $(px_msg)"

# PR 2: colorama out, toolz in
note "PR 2: replace $OUTSIDE with $ADD2"
sed -i "s/^$OUTSIDE = \"\*\"$/$ADD2 = \"*\"/" "$P/pixi.toml"
t_al=$SECONDS
out=$(CACHE_VOLUME=scn-s6-ci2 "$SCN_DIR/allowlist-ci.sh" all "$P" 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
ev "allowlist-ci.sh all (PR 2): exit $rc; $(grep -E 'apply:|^allowlist-ci:   [+-]' <<<"$out" | tr '\n' ' ')"
[[ $rc == 0 && -z $(lock_has "$P" "$OUTSIDE") && -n $(lock_has "$P" "$ADD2") ]]; check $? "PR 2: allowlist-ci.sh drops $OUTSIDE from the lock and the allowlist, adds $ADD2, and the project installs through conda-virtual" "exit $rc: $(tail -2 <<<"$out" | tr '\n' ' ')"
A="$WORK/s6/add"; project_copy "$A"; px ak "$A" new:scn-s6-add add --no-install "$OUTSIDE"; msg=$(px_msg)
r=$(akget "$(consumer_tok)" "conda/conda-virtual/$OUTSIDE_FILE")
ev "AK direct after PR 2: pixi add $OUTSIDE: exit $PX_RC: $msg; GET $OUTSIDE_FILE: HTTP ${r%% *} $(head -c 100 "$WORK/last.body")"
[[ $PX_RC != 0 && $msg == "No candidates were found for $OUTSIDE"* && ${r%% *} == 404 ]]; check $? "PR 2: through conda-virtual, $OUTSIDE is at once \"$msg\" and its file 404" "exit $PX_RC $msg, HTTP $r"
s=$(wait_nexus "$OUTSIDE" absent); rcw=$?
ev "Nexus's ak-virtual index drops $OUTSIDE $s s after the wait began ($((SECONDS - t_al)) s after allowlist-ci.sh started)"
project_copy "$A"; px nexus "$A" new:scn-s6-add-nx add --no-install "$OUTSIDE"; msg=$(px_msg)
ev "through Nexus after the TTL: pixi add $OUTSIDE: exit $PX_RC: $msg"
[[ $rcw == 0 && $PX_RC != 0 && $msg == "No candidates were found for $OUTSIDE"* ]]; check $? "PR 2: through Nexus, after the TTL, $OUTSIDE is \"$msg\"" "exit $PX_RC: $msg"
r=$(nxget ak-virtual "$OUTSIDE_FILE")
ev "through Nexus after the TTL: GET $OUTSIDE_FILE: HTTP $r (cached in PR 1)"
[[ ${r%% *} == 200 ]]; check $? "PR 2 caveat: Nexus still serves the $OUTSIDE file it cached in PR 1 (HTTP 200): Nexus does not revoke cached files, only the index is filtered" "HTTP $r"
