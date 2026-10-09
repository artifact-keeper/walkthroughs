#!/usr/bin/env bash
# S4 merged-in-the-artifact-manager, ProGet: a ProGet conda feed with two connectors merges
# Artifact Keeper's conda-virtual with a public source, and the client uses that feed.
#   merged       = [ak-virtual, cf-direct]  (conda.anaconda.org/conda-forge)
#   merged-fake  = [ak-virtual, scn-fake]   (scn-fake-forge: acme-core 99.0.0, and another
#                                            file under the name of our acme-core 1.0.0)
# "(bad)" marks behaviour the merge-in-the-manager design causes, "(good)" the fix.
#   1. (bad) the AK allowlist is undone: colorama resolves and downloads through merged
#   2. (bad) dependency confusion: an unpinned acme-core locks fake-forge's 99.0.0
#   3. a file name clash: ProGet takes record AND bytes from one connector, chosen by the
#      connectors' NAMES (alphabetical), not by their order in the feed:
#      3a merged-fake: ak-virtual sorts first, ours installs
#      3b (bad) a feed [ak-virtual, aaa-fake] (the same fake-forge under a name that sorts
#         first): the fake bytes install silently, the lock carries the fake sha256
#   4. (good) the fix: the hostile source as a member of AK's virtual (scn-virtual, through
#      the ProGet feed ak-scn-virtual): name guard, the hosted acme-core, the clash file installs
# ProGet's feeds have no base_url problem (ProGet writes its own info without base_url), so
# the client's channel is the feed URL itself.
# Restores the allowlist, the fake upstream's repodata, and removes temporary feeds and
# connectors, also on failure.
set -uo pipefail
AM=proget
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scn_begin S4 merged-in-the-artifact-manager-proget "a ProGet feed with two connectors merges conda-virtual with a public source"
ev "feeds: merged $(pgapi GET /feeds/get/merged | jq -c .connectors), merged-fake $(pgapi GET /feeds/get/merged-fake | jq -c .connectors)"
al_save
proj() { # DIR CHANNEL DEPS-TOML-LINES
  rm -rf "$1"; mkdir -p "$1"
  printf '[workspace]\nname = "s4"\nchannels = ["%s"]\nplatforms = ["linux-64"]\nchannel-priority = "strict"\n[dependencies]\npython = "3.12.*"\n%s\n' "$2" "$3" > "$1/pixi.toml"; }
PLAIN="$WORK/pixi-config-pg-plain.toml"; printf 'tls-root-certs = "system"\n' > "$PLAIN"
F10=acme-core-1.0.0-pyh4616a5c_0.conda

# 1. allowlist undone
note "1. allowlist ON, client on the merged feed"
ev "allowlist ON: $(al_on_from_lock)"
ev "ak-virtual index rebuilt (UI Local Index > delete): $(pg_reindex ak-virtual ak-virtual)"
ev "cf-direct index (conda-forge) ready: $(pg_warm cf-direct cf-direct)"
pg_feed s4-virtual ak-virtual; pg_feed s4-merged ak-virtual cf-direct   # fresh feeds: no cached packages
r=$(pgget s4-merged noarch/repodata.json); ev "s4-merged [ak-virtual, cf-direct] noarch/repodata.json: HTTP $r (cf-direct's index: $(pg_index cf-direct | awk '{printf "%.0f MB", $1/1e6}'))"
b=$(recs "$OUTSIDE" < "$WORK/last.body")
r1=$(pgget s4-virtual noarch/repodata.json); a=$(recs "$OUTSIDE" < "$WORK/last.body")
ev "$OUTSIDE records: through a feed on ak-virtual alone $a (HTTP ${r1%% *}), through the merged feed $b (HTTP ${r%% *})"
d1=$(pgget s4-virtual "$OUTSIDE_FILE"); d2=$(pgget s4-merged "$OUTSIDE_FILE")
ev "download $OUTSIDE_FILE: through ak-virtual alone HTTP ${d1%% *}, through merged HTTP ${d2%% *}"
P="$WORK/s4p/merged"; proj "$P" "$PG_IN/conda/s4-merged" ""
px "$PLAIN" "$P" new:scn-s4p-1 add --no-install "$OUTSIDE"
added=$(grep -oE "Added ${OUTSIDE}[^ ]* [^ ]*" "$PX_OUT" | head -1)
ev "pixi add $OUTSIDE, channel = the merged feed: exit $PX_RC, ${PX_S} s: ${added:-$(px_msg)}"
[[ $a == 0 && $b -gt 0 && ${d2%% *} == 200 && -n $added ]]; check $? "(bad) the allowlist is undone by the merge: with it ON, $OUTSIDE has $a records through ak-virtual and $b through the merged feed, downloads (HTTP ${d2%% *}) and \"$added\"" "ak-virtual $a, merged $b, download ${d2%% *}, pixi: $(px_msg)"
ev "allowlist restored for the rest: $(al_off)"

# 2. dependency confusion through the merge
note "2. unpinned acme-core through merged-fake"
ev "scn-fake index ready: $(pg_warm scn-fake scn-fake 300)"
r=$(pgget merged-fake noarch/repodata.json); vers=$(jq -c '[.["packages.conda"][] | select(.name=="acme-core") | .version] | unique' "$WORK/last.body")
P="$WORK/s4p/confusion"; proj "$P" "$PG_IN/conda/merged-fake" 'acme-core = "*"'
px "$PLAIN" "$P" new:scn-s4p-2 lock; got=$(lock_version "$P" acme-core)
ev "merged-fake offers acme-core $vers (noarch/repodata.json HTTP ${r%% *}); unpinned lock: exit $PX_RC, ${PX_S} s, acme-core ${got:-none}"
[[ $got == 99.0.0 ]]; check $? "(bad) dependency confusion: an unpinned acme-core through the merged feed locks fake-forge's 99.0.0 (no name ownership in the merge)" "locked ${got:-nothing}: $(px_msg)"

# 3. file name clash
note "3. $F10: same file name in both connectors"
ours=$(akcurl -fsS -H "Authorization: Bearer $(<"$(consumer_tok)")" "$U/conda/conda-internal/noarch/$F10" | sha256sum | cut -c1-64)
theirs=$(sha256sum < "$WORK/fake-forge/noarch/$F10" | cut -c1-64)
clash() { # FEED LABEL -> sets REC SERVED LOCKED IRC IMSG
  pgget "$1" noarch/repodata.json >/dev/null; REC=$(jq -r --arg f "$F10" '.["packages.conda"][$f].sha256' "$WORK/last.body")
  SERVED=$(curl -fsS "$PGF/$1/noarch/$F10" | sha256sum | cut -c1-64)
  local P="$WORK/s4p/clash-$1"; proj "$P" "$PG_IN/conda/$1" 'acme-core = "==1.0.0"'
  px "$PLAIN" "$P" "new:scn-s4p-3-$1" lock; LOCKED=$(sed -n "/^- conda: .*\/$F10\$/,/^- /p" "$P/pixi.lock" | grep -m1 -oE 'sha256: [0-9a-f]{64}' | cut -c9-)
  px "$PLAIN" "$P" "new:scn-s4p-3-$1" install --locked; IRC=$PX_RC; IMSG=$([[ $PX_RC == 0 ]] && px_tail 1 || px_msg)
  ev "$2: record ${REC:0:16}, bytes ${SERVED:0:16}, lock ${LOCKED:0:16}; install --locked exit $IRC: $IMSG"; }
ev "$F10: conda-internal sha256 ${ours:0:16}, fake-forge ${theirs:0:16}"
clash merged-fake "3a merged-fake [ak-virtual, scn-fake]"
[[ $REC == "$ours" && $SERVED == "$ours" && $IRC == 0 ]]; check $? "3a: the clash resolves to one connector for record and bytes (ours, ${ours:0:12}...; ak-virtual sorts before scn-fake), the install works" "record ${REC:0:12} bytes ${SERVED:0:12} exit $IRC"
pg_connector aaa-fake http://scn-fake-forge:8000; pg_feed s4-clash ak-virtual aaa-fake
ev "feed s4-clash connectors (as stored): $(pgapi GET /feeds/get/s4-clash | jq -c .connectors)"
clash s4-clash "3b s4-clash [ak-virtual, aaa-fake]"
[[ $REC == "$theirs" && $SERVED == "$theirs" && $LOCKED == "$theirs" && $IRC == 0 ]]; check $? "(bad) 3b: a squatter connector whose name sorts first wins the clash although listed second: the fake $F10 (${theirs:0:12}...) locks and installs without any error" "record ${REC:0:12} bytes ${SERVED:0:12} lock ${LOCKED:0:12} exit $IRC"

# 4. the fix: the hostile source is a member of AK's virtual (scn-virtual)
note "4. the same hostile content as a member of Artifact Keeper's virtual (scn-virtual via the ProGet feed ak-scn-virtual)"
fu_add_file "$WORK/fake-forge/noarch/$F10" "noarch/$F10"
fu_patch noarch '.["packages.conda"][$f] = (.["packages.conda"][$f99] + {version: "1.0.0", scn_fake: true})' --arg f "$F10" \
  --arg f99 "$(jq -r '.["packages.conda"] | keys[] | select(startswith("acme-core-99.0.0"))' "$FU/noarch/.scn-orig.json" 2>/dev/null || basename "$FU"/noarch/acme-core-99.0.0-*.conda)"
w=$(fu_wait noarch '[.["packages.conda"][] | select(.name=="acme-core")] | length == 2' 120); ev "AK's conda-fake-upstream serves acme-core 1.0.0 (clash) and 99.0.0 after ${w} s"
fu_channeldata > "$WORK/fcd.txt"; ev "workaround (S1 3): the fake upstream gets a channeldata.json for this run: $(<"$WORK/fcd.txt")"
ev "ak-scn-virtual index rebuilt: $(pg_reindex ak-scn-virtual ak-scn-virtual)"
pg_feed s4-scn ak-scn-virtual
r=$(pgget s4-scn noarch/repodata.json); vers=$(jq -c '[.["packages.conda"][] | select(.name=="acme-core") | .version] | unique' "$WORK/last.body")
rec=$(jq -r --arg f "$F10" '.["packages.conda"][$f].sha256' "$WORK/last.body")
ev "scn-virtual through ProGet: acme-core $vers; record for $F10 sha256 ${rec:0:16} (ours ${ours:0:16})"
SC=$(pg_config ak-virtual); sed -i "s|/conda/ak-scn-virtual\"|/conda/s4-scn\"|" "$SC"
P="$WORK/s4p/fix"; proj "$P" "https://ak.internal/conda/scn-virtual" 'acme-core = "*"'
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px "$SC" "$P" new:scn-s4p-4 lock; got=$(lock_version "$P" acme-core)
ev "unpinned lock through ProGet -> scn-virtual: exit $PX_RC, ${PX_S} s, acme-core ${got:-none}"
[[ $vers != *99.0.0* && $rec == "$ours" && -n $got && $got != 99.0.0 ]]; check $? "(good) as a member of AK's virtual the hostile source is dropped by the name guard: acme-core $vers, unpinned lock $got" "offers $vers, record ${rec:0:12}, locked ${got:-none}"
P="$WORK/s4p/fix-clash"; proj "$P" "https://ak.internal/conda/scn-virtual" 'acme-core = "==1.0.0"'
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px "$SC" "$P" new:scn-s4p-4b lock
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px "$SC" "$P" new:scn-s4p-4b install --locked
ev "acme-core ==1.0.0 through ProGet -> scn-virtual: install exit $PX_RC: $( [[ $PX_RC == 0 ]] && px_tail 1 || px_msg)"
[[ $PX_RC == 0 ]]; check $? "(good) the clash file name installs: record and bytes are both conda-internal's" "$(px_msg)"
