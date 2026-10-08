#!/usr/bin/env bash
# S4 merged-in-the-artifact-manager: the counter-example. A Nexus conda group merges
# Artifact Keeper's conda-virtual with a public source, and the client uses the group.
#   merged       = [ak-virtual, cf-direct]  (conda.anaconda.org/conda-forge)
#   merged-fake  = [ak-virtual, scn-fake]   (scn-fake-forge: acme-core 99.0.0, and another
#                                            file under the name of our acme-core 1.0.0)
# Each check passes when the expected behaviour is observed; "(bad)" marks behaviour
# that the merge-in-Nexus design causes, "(good)" the fix.
#   1. (bad) the AK allowlist is undone: colorama resolves and downloads through merged
#   2. (bad) dependency confusion: an unpinned acme-core locks fake-forge's 99.0.0
#   3. (bad) a file name clash: the group's record and bytes come from different members,
#      pixi refuses with a hash mismatch
#   4. (good) the fix: the hostile source as a member of AK's virtual (scn-virtual, through
#      Nexus as a plain proxy): name guard, the hosted acme-core, the clash file installs
# Restores the allowlist and the fake upstream's repodata, also on failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
scn_begin S4 merged-in-the-artifact-manager "a Nexus group merges conda-virtual with a public source"
ev "groups: merged $(nxapi GET /v1/repositories/conda/group/merged | jq -c .group.memberNames), merged-fake $(nxapi GET /v1/repositories/conda/group/merged-fake | jq -c .group.memberNames)"
on_exit 'echo "   $(nx_invalidate ak-virtual)"'
al_save
cnt() { jq --arg n "$1" '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name == $n)] | length'; }
proj() { # DIR CHANNEL DEPS-TOML-LINES
  rm -rf "$1"; mkdir -p "$1"
  printf '[workspace]\nname = "s4"\nchannels = ["%s"]\nplatforms = ["linux-64"]\nchannel-priority = "strict"\n[dependencies]\npython = "3.12.*"\n%s\n' "$2" "$3" > "$1/pixi.toml"; }

# Group caches: a Nexus conda group keeps its merged index until a member's content
# changes. During this work a group once answered linux-64/repodata.json.bz2 with
# {"packages":{}} (54 bytes) from such a cache, and the solve said "No candidates were found
# for python". So each group is invalidated and warmed after its members, and an empty
# merge is recorded and rebuilt once.
group_warm() { # GROUP
  local g=$1 sub r n
  echo "   $(nx_invalidate "$g")"
  for sub in noarch linux-64; do
    r=$(nxget "$g" "$sub/repodata.json.bz2"); n=$(bzip2 -dc "$WORK/last.body" 2>/dev/null | jq '(.["packages.conda"] // {} | length) + (.packages // {} | length)' 2>/dev/null)
    if (( ${n:-0} == 0 )); then
      ev "group $g $sub/repodata.json.bz2: HTTP $r with ${n:-no} records ($(bzip2 -dc "$WORK/last.body" 2>/dev/null | head -c 60)); invalidating and rebuilding"
      echo "   $(nx_invalidate "$g")"; r=$(nxget "$g" "$sub/repodata.json.bz2"); n=$(bzip2 -dc "$WORK/last.body" | jq '(.["packages.conda"] // {} | length) + (.packages // {} | length)')
    fi
    ev "group $g $sub/repodata.json.bz2 built: HTTP ${r%% *}, $(awk '{printf "%.1f MB in %.0f s", $2/1e6, $3}' <<<"$r"), $n records"
  done; }

# 1. allowlist undone
note "1. allowlist ON, client on the merged group"
ev "allowlist ON: $(al_on_from_lock)"
echo "   $(nx_invalidate ak-virtual)"
nxget ak-virtual noarch/repodata.json.bz2 >/dev/null; nxget ak-virtual linux-64/repodata.json.bz2 >/dev/null
group_warm merged
r=$(nxget ak-virtual noarch/repodata.json.bz2); a=$(bzip2 -dc "$WORK/last.body" | cnt "$OUTSIDE")
r2=$(nxget merged noarch/repodata.json.bz2); b=$(bzip2 -dc "$WORK/last.body" | cnt "$OUTSIDE")
ev "$OUTSIDE records: through ak-virtual $a (noarch .bz2 $r), through the group merged $b (noarch .bz2 $r2)"
d1=$(nxget ak-virtual "$OUTSIDE_FILE"); d2=$(nxget merged "$OUTSIDE_FILE")
ev "download $OUTSIDE_FILE: through ak-virtual HTTP ${d1%% *}, through merged HTTP ${d2%% *}"
P="$WORK/s4/merged"; proj "$P" "$NX_IN/repository/merged" ""
px "$(group_config merged)" "$P" new:scn-s4-1 add --no-install "$OUTSIDE"
added=$(grep -oE "Added ${OUTSIDE}[^ ]* [^ ]*" "$PX_OUT" | head -1)
ev "pixi add $OUTSIDE, channel = the group merged: exit $PX_RC, ${PX_S} s: ${added:-$(px_msg)}"
[[ $a == 0 && $b -gt 0 && ${d2%% *} == 200 && -n $added ]]; check $? "(bad) the allowlist is undone by the merge: with it ON, $OUTSIDE has $a records through ak-virtual and $b through the group, downloads (HTTP ${d2%% *}) and \"$added\"" "ak-virtual $a, merged $b, download ${d2%% *}, pixi: $(px_msg)"
ev "allowlist restored for the rest: $(al_off)"

# 2. dependency confusion through the merge
note "2. unpinned acme-core through merged-fake"
echo "   $(nx_invalidate ak-virtual)"; echo "   $(nx_invalidate scn-fake)"
for p in noarch/repodata.json.bz2 linux-64/repodata.json.bz2; do nxget ak-virtual "$p" >/dev/null; nxget scn-fake "$p" >/dev/null; done
group_warm merged-fake
P="$WORK/s4/confusion"; proj "$P" "$NX_IN/repository/merged-fake" 'acme-core = "*"'
px "$(group_config merged-fake)" "$P" new:scn-s4-2 lock; got=$(lock_version "$P" acme-core)
r=$(nxget merged-fake noarch/repodata.json.bz2); vers=$(bzip2 -dc "$WORK/last.body" | jq -c '[.["packages.conda"][] | select(.name=="acme-core") | .version] | unique')
ev "merged-fake offers acme-core $vers; unpinned lock: exit $PX_RC, ${PX_S} s, acme-core ${got:-none}"
[[ $got == 99.0.0 ]]; check $? "(bad) dependency confusion: an unpinned acme-core through the group locks fake-forge's 99.0.0 (no name ownership in the merge)" "locked ${got:-nothing}: $(px_msg)"

# 3. file name clash
note "3. acme-core 1.0.0: same file name in both members"
F10=acme-core-1.0.0-pyh4616a5c_0.conda
ours=$(akcurl -fsS -H "Authorization: Bearer $(<"$(consumer_tok)")" "$U/conda/conda-internal/noarch/$F10" | sha256sum | cut -c1-64)
theirs=$(sha256sum < "$WORK/fake-forge/noarch/$F10" | cut -c1-64)
rec=$(bzip2 -dc "$WORK/last.body" | jq -r --arg f "$F10" '.["packages.conda"][$f].sha256')
served=$(curl -fsS "$NXR/merged-fake/noarch/$F10" | sha256sum | cut -c1-64)
ev "$F10: conda-internal sha256 ${ours:0:16}, fake-forge ${theirs:0:16}; merged-fake record ${rec:0:16}, merged-fake bytes ${served:0:16}"
P="$WORK/s4/clash"; proj "$P" "$NX_IN/repository/merged-fake" 'acme-core = "==1.0.0"'
px "$(group_config merged-fake)" "$P" new:scn-s4-3 lock; ev "lock acme-core ==1.0.0: exit $PX_RC, sha256 in the lock $(sed -n "/^- conda: .*\/$F10\$/,/^- /p" "$P/pixi.lock" | grep -m1 -oE 'sha256: [0-9a-f]{16}')"
px "$(group_config merged-fake)" "$P" new:scn-s4-3 install --locked; msg=$(px_msg)
ev "install --locked: exit $PX_RC: $msg"
sed -n '/^Error/,$p' "$PX_OUT" | head -8 | sed 's/^/    /'
[[ $PX_RC != 0 && $msg == hash\ mismatch* && $rec != "$served" ]]; check $? "(bad) file name clash: the group's record and its bytes come from different members, pixi refuses: \"${msg:0:60}... expected ${rec:0:12}..., got ${served:0:12}...\"" "exit $PX_RC: $msg"

# 4. the fix: the hostile source is a member of AK's virtual (scn-virtual)
note "4. the same hostile content as a member of Artifact Keeper's virtual (scn-virtual via Nexus ak-scn-virtual)"
fu_add_file "$WORK/fake-forge/noarch/$F10" "noarch/$F10"
fu_patch noarch '.["packages.conda"][$f] = (.["packages.conda"][$f99] + {version: "1.0.0", scn_fake: true})' --arg f "$F10" \
  --arg f99 "$(jq -r '.["packages.conda"] | keys[] | select(startswith("acme-core-99.0.0"))' "$FU/noarch/.scn-orig.json" 2>/dev/null || basename "$FU"/noarch/acme-core-99.0.0-*.conda)"
w=$(fu_wait noarch '[.["packages.conda"][] | select(.name=="acme-core")] | length == 2' 120); ev "AK's conda-fake-upstream serves acme-core 1.0.0 (clash) and 99.0.0 after ${w} s (remote cache TTL $(akapi GET /repositories/conda-fake-upstream/cache-ttl | jq .cache_ttl_seconds) s)"
echo "   $(nx_invalidate ak-scn-virtual)"
r=$(nxget ak-scn-virtual noarch/repodata.json.bz2); vers=$(bzip2 -dc "$WORK/last.body" | jq -c '[.["packages.conda"][] | select(.name=="acme-core") | .version] | unique')
rec=$(bzip2 -dc "$WORK/last.body" | jq -r --arg f "$F10" '.["packages.conda"][$f].sha256')
ev "scn-virtual through Nexus: acme-core $vers; record for $F10 sha256 ${rec:0:16} (ours ${ours:0:16})"
P="$WORK/s4/fix"; proj "$P" "https://ak.internal/conda/scn-virtual" 'acme-core = "*"'
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px nexus "$P" new:scn-s4-4 lock; got=$(lock_version "$P" acme-core)
ev "unpinned lock through Nexus -> scn-virtual: exit $PX_RC, ${PX_S} s, acme-core ${got:-none}"
[[ $vers != *99.0.0* && $rec == "$ours" && -n $got && $got != 99.0.0 ]]; check $? "(good) as a member of AK's virtual the hostile source is dropped by the name guard: acme-core $vers, unpinned lock $got" "offers $vers, record ${rec:0:12}, locked ${got:-none}"
P="$WORK/s4/fix-clash"; proj "$P" "https://ak.internal/conda/scn-virtual" 'acme-core = "==1.0.0"'
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px nexus "$P" new:scn-s4-4b lock
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px nexus "$P" new:scn-s4-4b install --locked
ev "acme-core ==1.0.0 through Nexus -> scn-virtual: install exit $PX_RC: $( [[ $PX_RC == 0 ]] && px_tail 1 || px_msg)"
[[ $PX_RC == 0 ]]; check $? "(good) the clash file name installs: record and bytes are both conda-internal's" "$(px_msg)"
