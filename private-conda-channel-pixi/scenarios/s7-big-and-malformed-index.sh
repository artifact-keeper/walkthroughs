#!/usr/bin/env bash
# S7 big-and-malformed-index:
#   1. the size of the merged conda-virtual index per solve (allowlist as found, normally off):
#      what a monolithic client (conda classic, mamba without shards) downloads, per subdir
#      and encoding, and what pixi downloads for one cold-cache solve (bytes, time, files)
#   2. CEP-16 shards are not served through the virtual (artifact-keeper#4577): 404, while the
#      hosted member serves them; pixi falls back to repodata.json.zst
#   3. a malformed record from a public member: track_features as a JSON list instead of a
#      string (the shape that broke Artifactory, see the research). Served by the gate's
#      fake upstream to Artifact Keeper (member of scn-virtual) and by scn-fake-forge to Nexus
#      (member of the group merged-fake). AK must serve a valid merged index or fail loudly
#      with a message, never a 500 with a stack trace.
# Restores the fake upstream's and fake-forge's repodata, also on failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
scn_begin S7 big-and-malformed-index "index size per solve, shards, a malformed public record"
ev "allowlist as found: $(akapi GET /repositories/conda-virtual/allowlist | jq -c '{enabled, entry_count}')"
T=$(consumer_tok); BIG="$SCN_OUT/s7"; mkdir -p "$BIG"

# 1. monolithic clients
note "1. conda-virtual index, monolithic"
tot=0
for sub in noarch linux-64; do for f in repodata.json repodata.json.zst repodata.json.bz2 current_repodata.json; do
  r=$(akcurl -sS -o "$BIG/$sub-$f" -w '%{http_code} %{size_download} %{time_total}' -H "Authorization: Bearer $(<"$T")" "$U/conda/conda-virtual/$sub/$f")
  recs=""; [[ $f == repodata.json ]] && recs=", $(jq '(.["packages.conda"] // {} | length) + (.packages // {} | length)' "$BIG/$sub-$f") records"
  ev "GET conda-virtual/$sub/$f: HTTP ${r%% *}, $(echo "${r#* }" | awk '{printf "%.1f MB in %.1f s", $1/1e6, $2}')$recs"
  [[ $f == repodata.json.zst ]] && tot=$(( tot + $(cut -d' ' -f2 <<<"$r") ))
done; done
r=$(akcurl -sS -o "$BIG/channeldata.json" -w '%{http_code} %{size_download} %{time_total}' -H "Authorization: Bearer $(<"$T")" "$U/conda/conda-virtual/channeldata.json")
ev "GET conda-virtual/channeldata.json: HTTP ${r%% *}, $(echo "${r#* }" | awk '{printf "%.1f MB in %.1f s", $1/1e6, $2}')"
ev "a monolithic client solving for linux-64 downloads noarch + linux-64 repodata.json.zst: $(echo "$tot" | awk '{printf "%.1f MB", $1/1e6}') compressed per solve (uncompressed json: $(du -cb "$BIG"/noarch-repodata.json "$BIG"/linux-64-repodata.json | tail -1 | awk '{printf "%.1f MB", $1/1e6}'))"
rm -f "$BIG"/*repodata.json* "$BIG"/*current_repodata.json
pass "monolithic: the merged index per linux-64 solve is $(echo "$tot" | awk '{printf "%.1f MB", $1/1e6}') of repodata.json.zst (see evidence for every encoding)"

# 2. pixi, one cold-cache solve straight to AK; shards
note "2. pixi solve, shards"
C="$WORK/s7/solve"; project_copy "$C" conda-only; rm -f "$C/pixi.lock"
t=$(date +%s); px ak "$C" new:scn-s7-solve lock; sleep 1
ev "pixi lock (conda-only copy of project/, cold cache, straight to AK): exit $PX_RC, ${PX_S} s"
podman logs --since "$(date -u -d "@$t" +%FT%TZ)" ak-conda-caddy 2>&1 | grep '"uri"' | jq -r --argjson t "$t" \
  'select(.ts >= $t and (.request.uri | test("repodata|channeldata|shards"))) | "\(.status) \(.size) \(.request.uri)"' |
  sort | uniq -c | awk '{printf "    %s x%s %.1f MB %s\n", $2, $1, $3/1e6, $4}' | tee "$WORK/s7-pixi-index.txt"
pb=$(awk '$1 == 200 {b += $3 * 1e6} END {printf "%.1f", b/1e6}' "$WORK/s7-pixi-index.txt")
ev "pixi fetched $pb MB of index for this solve: $(awk '{print $1" "$5}' "$WORK/s7-pixi-index.txt" | sed 's|/conda/||' | tr '\n' ';')"
[[ $PX_RC == 0 ]]; check $? "pixi: one cold-cache solve through conda-virtual reads $pb MB of index in ${PX_S} s" "$(px_msg)"
for repo in conda-virtual conda-internal conda-forge; do
  r=$(akget "$T" "conda/$repo/noarch/repodata_shards.msgpack.zst"); ev "GET $repo/noarch/repodata_shards.msgpack.zst: HTTP $r $( [[ ${r%% *} != 200 ]] && head -c 120 "$WORK/last.body")"
  printf -v "SH_${repo//-/_}" '%s' "${r%% *}"
done
[[ $SH_conda_virtual == 404 && $SH_conda_internal == 200 ]]; check $? "shards: the hosted member serves CEP-16 shards (200), the virtual does not (404, artifact-keeper#4577): every pixi solve through the virtual downloads the full index" "virtual $SH_conda_virtual, internal $SH_conda_internal"

# 3. track_features as a list
note "3. a public record with track_features as a list"
REC='{"name":"scn-trackfeat","version":"1.0.0","build":"0","build_number":0,"depends":[],"license":"MIT","subdir":"linux-64","md5":"00000000000000000000000000000000","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size":1024,"timestamp":1700000000000,"track_features":["mkl","debug"]}'
FN=scn-trackfeat-1.0.0-0.conda
fu_patch linux-64 '.["packages.conda"][$fn] = $rec' --arg fn "$FN" --argjson rec "$REC"
ev "fake upstream linux-64 record: $(jq -c --arg fn "$FN" '.["packages.conda"][$fn] | {name, version, track_features}' "$FU/linux-64/repodata.json")"
w=$(fu_wait linux-64 '.["packages.conda"] | has("scn-trackfeat-1.0.0-0.conda")' 120); rcw=$?
r=$(akget "$SCN_TOKENS/scn-reader.token" conda/conda-fake-upstream/linux-64/repodata.json)
ev "AK conda-fake-upstream (the member alone) linux-64/repodata.json after ${w} s: HTTP $r; the record as served: $(jq -c --arg fn "$FN" '.["packages.conda"][$fn].track_features' "$WORK/last.body" 2>/dev/null)"
for f in repodata.json repodata.json.zst repodata.json.bz2; do
  r=$(akget "$SCN_TOKENS/scn-reader.token" "conda/scn-virtual/linux-64/$f"); code=${r%% *}
  case $f in *.zst) dec="zstd -dqc";; *.bz2) dec="bzip2 -dc";; *) dec=cat;; esac
  if [[ $code == 200 ]] && $dec "$WORK/last.body" > "$BIG/s7-merged.json" 2>/dev/null && jq -e . "$BIG/s7-merged.json" >/dev/null 2>&1; then
    tf=$(jq -c --arg fn "$FN" '.["packages.conda"][$fn].track_features // "record absent"' "$BIG/s7-merged.json")
    n=$(jq '(.["packages.conda"] | length) + (.packages | length)' "$BIG/s7-merged.json")
    ev "scn-virtual linux-64/$f: HTTP 200, valid JSON, $n records, scn-trackfeat track_features: $tf"
    printf -v "V_${f//./_}" '%s' "ok:$tf"
  else
    ev "scn-virtual linux-64/$f: HTTP $r: $(head -c 300 "$WORK/last.body" | tr '\n' ' ')"
    trace=$(grep -ciE 'panicked|backtrace|stack trace|at [a-z_:]+\(|\.rs:[0-9]+' "$WORK/last.body")
    printf -v "V_${f//./_}" '%s' "$code:$trace"
  fi
done
rm -f "$BIG/s7-merged.json"
res="$V_repodata_json $V_repodata_json_zst $V_repodata_json_bz2"
if [[ $V_repodata_json == ok:* && $V_repodata_json_zst == ok:* && $V_repodata_json_bz2 == ok:* ]]; then
  pass "malformed public record: scn-virtual still serves a valid merged linux-64 index in json, zst and bz2 (track_features served as ${V_repodata_json#ok:})"
elif [[ $res != *500:* && $res != *:[1-9]* ]]; then
  pass "malformed public record: scn-virtual fails loudly without a stack trace ($res)"
else fail "malformed public record handled" "$res"; fi
P="$WORK/s7/tf"; rm -rf "$P"; mkdir -p "$P"
printf '[workspace]\nname = "s7"\nchannels = ["https://ak.internal/conda/scn-virtual"]\nplatforms = ["linux-64"]\n[dependencies]\npython = "3.12.*"\n' > "$P/pixi.toml"
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px ak "$P" new:scn-s7-tf lock
ev "pixi lock through scn-virtual with the malformed record present: exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $PX_RC == 0 ]]; check $? "pixi still solves through scn-virtual with the malformed record in the merge" "$(px_msg)"
printf 'scn-trackfeat = "*"\n' >> "$P/pixi.toml"; rm -f "$P/pixi.lock"
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px ak "$P" new:scn-s7-tf2 lock
ev "pixi lock that selects scn-trackfeat (rattler must parse the record): exit $PX_RC: $( [[ $PX_RC == 0 ]] && echo "locked $(lock_has "$P" scn-trackfeat | sed 's|.*/||')" || px_msg)"
[[ $PX_RC != 0 ]] && sed -n '/^Error/,$p' "$PX_OUT" | head -6 | sed 's/^/    /'
if [[ $PX_RC == 0 ]]; then pass "pixi (rattler) accepts the list-shaped track_features and locks scn-trackfeat"
elif grep -qi 'track_features' "$PX_OUT"; then pass "pixi (rattler) rejects the list-shaped track_features with a message naming it: \"$(px_msg)\""
else fail "pixi handles the list-shaped track_features" "$(px_msg)"; fi

# Nexus: the same record from scn-fake-forge, merged by the group merged-fake
FF="$WORK/fake-forge/linux-64/repodata.json"; cp "$FF" "$WORK/s7-ff-linux-64.orig"
on_exit 'cp "$WORK/s7-ff-linux-64.orig" "$FF"; echo "   fake-forge linux-64/repodata.json restored"; echo "   $(nx_invalidate scn-fake)"'
jq -c --arg fn "$FN" --argjson rec "$REC" '.["packages.conda"][$fn] = $rec' "$WORK/s7-ff-linux-64.orig" > "$FF"
echo "   $(nx_invalidate scn-fake)"
r=$(nxget scn-fake linux-64/repodata.json); ev "Nexus scn-fake (proxy of scn-fake-forge) linux-64/repodata.json: HTTP $r; track_features $(jq -c --arg fn "$FN" '.["packages.conda"][$fn].track_features' "$WORK/last.body" 2>/dev/null)"
r=$(nxget merged-fake linux-64/repodata.json.bz2)
if [[ ${r%% *} == 200 ]]; then tf=$(bzip2 -dc "$WORK/last.body" | jq -c --arg fn "$FN" '.["packages.conda"][$fn].track_features // "record absent"' 2>/dev/null || echo "invalid JSON")
else tf=$(head -c 200 "$WORK/last.body" | tr '\n' ' '); fi
ev "Nexus group merged-fake linux-64/repodata.json.bz2: HTTP $r; scn-trackfeat track_features: $tf"
[[ ${r%% *} == 200 && $tf == *mkl* ]]; check $? "Nexus passes the list-shaped track_features through too: the group merged-fake answers HTTP ${r%% *} and keeps it ($tf)" "HTTP $r: $tf"
