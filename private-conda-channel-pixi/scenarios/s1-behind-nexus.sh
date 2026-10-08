#!/usr/bin/env bash
# S1 behind-nexus: pixi's only conda source is Nexus, which proxies Artifact Keeper's
# conda-virtual (scenarios/nexus/pixi-config.toml: the lock keeps the ak.internal URLs,
# mirrors send every conda request to Nexus).
#   1. pixi install --locked with Nexus's package cache empty (cold), then again with a
#      new client cache (warm): time, bytes AK served Nexus, bytes Nexus served pixi
#   2. the lockfile is unchanged
#   3. name ownership through Nexus: scn-virtual (conda-virtual plus G4's fake upstream,
#      which publishes acme-core 99.0.0) never offers 99.0.0, and an unpinned solve
#      through Nexus keeps the hosted acme-core
#   4. allowlist ON: the time until Nexus serves the filtered index (the propagation
#      delay, bounded by Nexus's metadataMaxAge), then `pixi add colorama` is "No
#      candidates were found" and the download through Nexus is 404
# Restores the allowlist exactly as found and invalidates Nexus's metadata cache, also on failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
scn_begin S1 behind-nexus "pixi -> Nexus (proxy) -> Artifact Keeper conda-virtual"
TTL_MIN=$(nxapi GET /v1/repositories/conda/proxy/ak-virtual | jq -r .proxy.metadataMaxAge)
ev "Nexus ak-virtual: metadataMaxAge ${TTL_MIN} min, negative cache $(nxapi GET /v1/repositories/conda/proxy/ak-virtual | jq -r .negativeCache.timeToLive) min"
on_exit 'echo "   $(nx_invalidate ak-virtual)"'
al_save
D="$WORK/s1/project"; project_copy "$D"; lock0=$(sha256sum < "$D/pixi.lock")

# 1. cold, then warm
note "1. install --locked through Nexus"
n=$(nx_purge ak-virtual '\.(conda|tar\.bz2)$'); n2=$(nx_purge ak-internal '\.(conda|tar\.bz2)$')
ev "Nexus package cache emptied: $n assets from ak-virtual, $n2 from ak-internal"
for run in cold warm; do
  rm -rf "$D/.pixi"; t=$(date +%s); m=$(nx_mark)
  px nexus "$D" "new:scn-s1-$run" install --locked
  sleep 1; akb=$(ak_bytes_since "$t" Nexus); nxb=$(nx_bytes_since "$m")
  ev "$run install --locked: exit $PX_RC, ${PX_S} s; Nexus -> pixi: $(nx_served_since "$m")"
  ev "$run install --locked: ak.internal -> clients: $(ak_served_since "$t")"
  ok=$(( PX_RC != 0 )); grep -q 'environment has been installed' "$PX_OUT" || ok=1
  [[ $run == cold ]] && (( akb == 0 )) && ok=1
  [[ $run == warm ]] && (( akb != 0 )) && ok=1
  check $ok "$run: pixi install --locked through Nexus ($PX_S s; AK -> Nexus $(echo "scale=1; $akb/1000000" | bc) MB, Nexus -> pixi $(echo "scale=1; $nxb/1000000" | bc) MB)" "$(px_tail 2)"
done
# 2. lockfile
[[ $(sha256sum < "$D/pixi.lock") == "$lock0" ]]; check $? "pixi.lock unchanged by install --locked through Nexus (keeps the https://ak.internal URLs)"
ev "lock URLs: $(grep -c '^- conda: https://ak.internal/' "$D/pixi.lock") conda entries on https://ak.internal, $(grep -c 'scn-nexus' "$D/pixi.lock") mention scn-nexus"

# 3. name ownership through Nexus
note "3. name ownership: scn-virtual through Nexus (ak-scn-virtual)"
vers() { jq -c '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name=="acme-core") | .version] | unique'; }
akget "$(consumer_tok)" conda/conda-internal/noarch/repodata.json >/dev/null; hosted=$(vers < "$WORK/last.body")
top=$(jq -r 'sort_by(split(".") | map(tonumber? // .)) | last' <<<"$hosted")
akget "$SCN_TOKENS/scn-reader.token" conda/conda-fake-upstream/noarch/repodata.json >/dev/null; fake=$(vers < "$WORK/last.body")
r=$(nxget ak-scn-virtual noarch/repodata.json.bz2); bzip2 -dc "$WORK/last.body" > "$SCN_OUT/s1-scn-virtual-noarch.json" 2>/dev/null
via=$(vers < "$SCN_OUT/s1-scn-virtual-noarch.json")
ev "conda-internal acme-core: $hosted; fake upstream alone: $fake; scn-virtual through Nexus: $via (noarch .bz2: $r)"
[[ "$fake" == *99.0.0* && "$via" == "$hosted" ]]; check $? "scn-virtual through Nexus offers only the hosted acme-core $via (the fake upstream's 99.0.0 dropped by AK's name guard)" "offers $via"
G="$WORK/s1/guard"; rm -rf "$G"; mkdir -p "$G"
cat > "$G/pixi.toml" <<'TOML'
[workspace]
name = "s1-guard"
channels = ["https://ak.internal/conda/scn-virtual"]
platforms = ["linux-64"]
channel-priority = "strict"
[dependencies]
python = "3.12.*"
acme-core = "*"
TOML
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px nexus "$G" new:scn-s1-guard lock; got=$(lock_version "$G" acme-core)
ev "unpinned solve through Nexus: exit $PX_RC, ${PX_S} s, acme-core ${got:-none} from $(lock_has "$G" acme-core | sed -E 's|/[^/]*/[^/]*$||')"
[[ "$got" == "$top" ]]; check $? "unpinned 'acme-core = \"*\"' solved through Nexus locks the hosted $got, not 99.0.0" "${got:-$(px_tail 2)}"

# 4. allowlist propagation through Nexus's metadata cache
note "4. allowlist on: propagation through Nexus (metadataMaxAge ${TTL_MIN} min)"
n=$(nx_purge ak-virtual "/$OUTSIDE-"); ev "Nexus cached copies of $OUTSIDE removed: $n"
echo "   $(nx_invalidate ak-virtual)"
H="$WORK/s1.h"; NB="$SCN_OUT/s1-nexus-noarch.json.bz2"
cnt() { bzip2 -dc "$NB" | jq --arg n "$OUTSIDE" '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name == $n)] | length'; }
curl -sS -D "$H" -o "$NB" "$NXR/ak-virtual/noarch/repodata.json.bz2"; etag=$(tr -d '\r' < "$H" | awk 'tolower($1) == "etag:" {print $2}')
ev "t=0- Nexus noarch/repodata.json.bz2 just revalidated: $(stat -c %s "$NB") bytes, $OUTSIDE records $(cnt), ETag $etag"
t_on=$(date +%s.%N); al=$(al_on_from_lock); ev "allowlist ON: $al"
r=$(nxget ak-virtual "$OUTSIDE_FILE"); ev "t=+$(printf %.0f "$(echo "$(date +%s.%N) - $t_on" | bc)")s download $OUTSIDE through Nexus: HTTP ${r%% *} (downloads are not cached metadata: AK answers at once)"
P="$WORK/s1/add"; project_copy "$P"
px nexus "$P" new:scn-s1-add-early add --no-install "$OUTSIDE"
early=$(grep -oE "Added ${OUTSIDE}[^ ]* [^ ]*" "$PX_OUT" | head -1)
ev "t=+$(printf %.0f "$(echo "$(date +%s.%N) - $t_on" | bc)")s pixi add $OUTSIDE through Nexus: exit $PX_RC: ${early:-$(px_msg)}"
seen=""; deadline=$(( $(date +%s) + TTL_MIN * 60 * 3 + 120 ))
while (( $(date +%s) < deadline )); do
  c=$(curl -sS -D "$H" -o "$WORK/s1.poll" -w '%{http_code}' -H "If-None-Match: $etag" "$NXR/ak-virtual/noarch/repodata.json.bz2")
  if [[ $c == 200 ]]; then
    mv "$WORK/s1.poll" "$NB"; etag=$(tr -d '\r' < "$H" | awk 'tolower($1) == "etag:" {print $2}')
    if [[ $(cnt) == 0 ]]; then seen=$(echo "$(date +%s.%N) - $t_on" | bc); break; fi
  fi
  sleep 5
done
if [[ -n $seen ]]; then
  SEEN=$(printf %.0f "$seen")
  ev "PROPAGATION: Nexus served the filtered noarch index ${SEEN} s after allowlist ON ($(stat -c %s "$NB") bytes, $OUTSIDE records 0; metadataMaxAge ${TTL_MIN} min, polled every 5 s with If-None-Match)"
  (( SEEN <= TTL_MIN * 60 + 60 )); check $? "allowlist reaches Nexus clients ${SEEN} s after it is set (bound: metadataMaxAge ${TTL_MIN} min)" "longer than the TTL"
else fail "allowlist reaches Nexus clients within 3 x metadataMaxAge" "still $OUTSIDE records after $(( TTL_MIN * 3 + 2 )) min"; fi
[[ -n $early ]]; check $? "inside the window, pixi add $OUTSIDE through Nexus still succeeds from Nexus's cached index (\"$early\")" "$(px_msg)"
project_copy "$P"; px nexus "$P" new:scn-s1-add-late add --no-install "$OUTSIDE"; msg=$(px_msg)
ev "after propagation, pixi add $OUTSIDE through Nexus: exit $PX_RC: $msg"
sed -n '/^Error/,$p' "$PX_OUT" | head -6 | sed 's/^/    /'
[[ $PX_RC != 0 && $msg == "No candidates were found for $OUTSIDE"* ]]; check $? "after propagation, pixi add $OUTSIDE through Nexus fails: \"$msg\"" "exit $PX_RC $(px_tail 2)"
r=$(nxget ak-virtual "$OUTSIDE_FILE"); ev "download $OUTSIDE_FILE through Nexus: HTTP $r; body: $(grep -o '<title>[^<]*' "$WORK/last.body" | head -1)"
[[ ${r%% *} == 404 ]]; check $? "download of $OUTSIDE through Nexus is 404" "HTTP $r"
