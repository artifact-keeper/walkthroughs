#!/usr/bin/env bash
# S6 allowlist-from-a-pull-request, ProGet: the CI loop (scenarios/allowlist-ci.sh) with
# ProGet Free in front of conda-virtual.
#   PR 1  a copy of project/ adds colorama: lock against the unfiltered twin, allowlist from
#         the new lock; colorama installs through conda-virtual at once and through ProGet
#         once ProGet has updated its index (nobody touches ProGet: ~10 min index age + rebuild)
#   PR 2  the same copy swaps colorama for toolz: colorama is "not found" through
#         conda-virtual at once and through ProGet after the update; toolz installs. The feed
#         that cached colorama in PR 1 keeps listing and serving it (recorded: ProGet merges
#         cached packages into a feed's index)
# Each PR is watched through a fresh feed (empty package cache) over the ak-virtual connector.
# Restores the allowlist exactly as found and removes the temporary feeds, also on failure.
set -uo pipefail
AM=proget
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scn_begin S6 allowlist-from-a-pull-request-proget "a dependency change goes through CI to the allowlist, ProGet in front"
ADD2=${ADD2:-toolz}
al_save
P="$WORK/s6p/pr"; project_copy "$P"
"$ROOT/allowlist/from-lock.sh" --list "$ROOT/project/pixi.lock" | cut -f1 | grep -qx "$OUTSIDE" && { fail "setup" "$OUTSIDE already in project/pixi.lock"; exit 1; }

note "baseline: allowlist from project/pixi.lock, ProGet caught up"
ev "baseline allowlist: $(al_on_from_lock)"
ev "baseline: ak-virtual index rebuilt (Local Index > delete): $(pg_reindex ak-virtual ak-virtual)"
pg_feed s6-pr1 ak-virtual; pg_feed s6-pr2 ak-virtual
pgget s6-pr1 noarch/repodata.json >/dev/null; n=$(recs "$OUTSIDE" < "$WORK/last.body")
ev "baseline: $OUTSIDE records through ProGet: $n"
[[ $n == 0 ]] || { fail "baseline" "$OUTSIDE still listed through ProGet"; exit 1; }

# PR 1
note "PR 1: add $OUTSIDE"
sed -i "s/^python = \"3.12.\*\"$/&\n$OUTSIDE = \"*\"/" "$P/pixi.toml"
t_al=$SECONDS
out=$(CACHE_VOLUME=scn-s6p-ci1 "$SCN_DIR/allowlist-ci.sh" all "$P" 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
ev "allowlist-ci.sh all (PR 1): exit $rc; $(grep -E 'apply:|^allowlist-ci:   [+-]' <<<"$out" | tr '\n' ' ')"
lk=$(lock_has "$P" "$OUTSIDE")
[[ $rc == 0 && $lk == https://ak.internal/conda/conda-virtual/* ]]; check $? "PR 1: allowlist-ci.sh locks $OUTSIDE against the unfiltered twin, sets the allowlist, and install --locked through conda-virtual passes" "exit $rc: $(tail -2 <<<"$out" | tr '\n' ' ')"
s=$(pg_wait_listing s6-pr1 "$OUTSIDE" present); rcw=$?
ev "ProGet lists $OUTSIDE $s s after the wait began ($((SECONDS - t_al)) s after allowlist-ci.sh started); ProGet's index $(pg_index_age ak-virtual) s old"
D="$WORK/s6p/via-proget"; rm -rf "$D"; mkdir -p "$D"; cp "$P/pixi.toml" "$P/pixi.lock" "$D/"
px "$(pg_config s6-pr1)" "$D" new:scn-s6p-1 install --locked
ev "pixi install --locked through ProGet after its update: exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $rcw == 0 && $PX_RC == 0 ]]; check $? "PR 1: through ProGet, once ProGet updated its index ($((SECONDS - t_al)) s after the job started), the new lock installs including $OUTSIDE" "wait rc $rcw; $(px_msg)"

# PR 2
note "PR 2: replace $OUTSIDE with $ADD2"
sed -i "s/^$OUTSIDE = \"\*\"$/$ADD2 = \"*\"/" "$P/pixi.toml"
t_al=$SECONDS
out=$(CACHE_VOLUME=scn-s6p-ci2 "$SCN_DIR/allowlist-ci.sh" all "$P" 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
ev "allowlist-ci.sh all (PR 2): exit $rc; $(grep -E 'apply:|^allowlist-ci:   [+-]' <<<"$out" | tr '\n' ' ')"
[[ $rc == 0 && -z $(lock_has "$P" "$OUTSIDE") && -n $(lock_has "$P" "$ADD2") ]]; check $? "PR 2: allowlist-ci.sh drops $OUTSIDE from the lock and the allowlist, adds $ADD2, and the project installs through conda-virtual" "exit $rc: $(tail -2 <<<"$out" | tr '\n' ' ')"
s=$(pg_wait_listing s6-pr2 "$OUTSIDE" absent); rcw=$?
ev "ProGet (fresh feed) drops $OUTSIDE $s s after the wait began ($((SECONDS - t_al)) s after allowlist-ci.sh started)"
A="$WORK/s6p/add"; project_copy "$A"; px "$(pg_config s6-pr2)" "$A" new:scn-s6p-add add --no-install "$OUTSIDE"; msg=$(px_msg)
ev "through ProGet after its update: pixi add $OUTSIDE: exit $PX_RC: $msg"
[[ $rcw == 0 && $PX_RC != 0 && $msg == "No candidates were found for $OUTSIDE"* ]]; check $? "PR 2: through ProGet, after its update ($((SECONDS - t_al)) s), $OUTSIDE is \"$msg\"" "exit $PX_RC: $msg"
D="$WORK/s6p/via-proget2"; rm -rf "$D"; mkdir -p "$D"; cp "$P/pixi.toml" "$P/pixi.lock" "$D/"
px "$(pg_config s6-pr2)" "$D" new:scn-s6p-2 install --locked
ev "PR 2 lock through ProGet: install --locked exit $PX_RC, ${PX_S} s"
[[ $PX_RC == 0 ]]; check $? "PR 2: the new lock ($ADD2) installs through ProGet" "$(px_msg)"
pgget s6-pr1 noarch/repodata.json >/dev/null; nc=$(recs "$OUTSIDE" < "$WORK/last.body"); r=$(pgget s6-pr1 "$OUTSIDE_FILE")
ev "the PR 1 feed (cached $OUTSIDE): lists it x$nc, GET $OUTSIDE_FILE HTTP ${r%% *}"
[[ $nc -gt 0 && ${r%% *} == 200 ]]; check $? "PR 2 caveat: the feed that cached $OUTSIDE in PR 1 still lists ($nc) and serves it (HTTP ${r%% *}): ProGet does not revoke cached packages, and lists them" "listed $nc, HTTP $r"
