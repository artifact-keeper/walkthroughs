#!/usr/bin/env bash
# S1 behind-proget: pixi's only conda source is ProGet Free, whose conda feeds have a
# connector to Artifact Keeper's conda-virtual (proget/pixi-config.toml: the lock keeps the
# ak.internal URLs, mirrors send every conda request to ProGet).
#   0. a connector whose local index was never built: install --locked gets 404 for every
#      package (package requests do not build the index); after one metadata request has
#      built it (time, bytes from AK), the same install works
#   1. install --locked with the feed's package cache empty (a fresh feed over the warm
#      connector) and again (warm): time, bytes AK served ProGet, bytes ProGet served pixi
#   2. the lockfile is unchanged
#   3. name ownership through ProGet: scn-virtual (conda-virtual plus G4's fake upstream with
#      acme-core 99.0.0) never offers 99.0.0, an unpinned solve keeps the hosted acme-core
#   4. a fresh solve through ProGet: time, and the records ProGet rewrites (noarch dropped:
#      the lock says "noarch: false" for noarch: python packages, and they still import)
#   5. allowlist ON: the time until ProGet serves the filtered index without anyone touching
#      it (bounded by the ~10 minute index age plus the rebuild), then pixi add colorama is
#      "No candidates were found"; and what a feed that had cached colorama does
# Restores the allowlist exactly as found and removes temporary feeds and connectors, also on failure.
set -uo pipefail
AM=proget
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scn_begin S1 behind-proget "pixi -> ProGet Free (conda feed, connector) -> Artifact Keeper conda-virtual"
al_save
# a known starting point: the ak-virtual index rebuilt now, with the allowlist as found (an
# earlier scenario may have left ProGet holding an index built with the allowlist on)
ev "ak-virtual index rebuilt (Local Index > delete), allowlist $(akapi GET /repositories/conda-virtual/allowlist | jq -c '{enabled}'): $(pg_reindex ak-virtual ak-virtual)"
D="$WORK/s1p/project"; project_copy "$D"; lock0=$(sha256sum < "$D/pixi.lock")

# 0. never-built index
note "0. a connector whose index was never built"
pg_connector s1-cold "$AK_URL/conda/conda-virtual" "$TOKENS/consumer.token"; pg_feed s1-cold s1-cold; pg_feed s1-int ak-internal
CF=$(pg_config s1-cold s1-int)
t=$(date +%s); px "$CF" "$D" new:scn-s1p-0 install --locked; msg=$(px_msg)
ev "0. install --locked, index never built: exit $PX_RC, ${PX_S} s: $msg; ProGet -> AK: $(pg_upstream_since "$t")"
[[ $PX_RC != 0 && $msg == *404* ]]; check $? "(bad) 0: install --locked through a connector whose index was never built fails with 404 (\"$msg\"); package requests do not build it" "exit $PX_RC: $msg"
t=$(date +%s); w=$(pg_warm s1-cold s1-cold); ev "0. index built by metadata requests: $w; ProGet -> AK: $(ak_served_since "$t")"
rm -rf "$D/.pixi"; px "$CF" "$D" new:scn-s1p-0b install --locked
ev "0. install --locked after the index was built: exit $PX_RC, ${PX_S} s"
[[ $PX_RC == 0 ]]; check $? "0: after one metadata request built the index (${w%%,*}), the same install --locked works" "$(px_msg)"

# 1. cold, then warm package cache
note "1. install --locked through ProGet: fresh feeds (empty package cache) over warm connectors"
pg_feed s1-pkg ak-virtual; pg_feed s1-pint ak-internal; C1=$(pg_config s1-pkg s1-pint)
for run in cold warm; do
  rm -rf "$D/.pixi"; t=$(date +%s); sleep 1
  px "$C1" "$D" "new:scn-s1p-$run" install --locked
  sleep 2; akb=$(ak_bytes_since "$t" ProGet); pgb=$(pg_bytes_since "$t")
  ev "$run install --locked: exit $PX_RC, ${PX_S} s; ProGet -> pixi: $(pg_served_since "$t")"
  ev "$run install --locked: ak.internal -> clients: $(ak_served_since "$t")"
  ok=$(( PX_RC != 0 )); grep -q 'environment has been installed' "$PX_OUT" || ok=1
  [[ $run == cold ]] && (( akb == 0 )) && ok=1
  [[ $run == warm ]] && (( akb != 0 )) && ok=1
  check $ok "1 $run: pixi install --locked through ProGet ($PX_S s; AK -> ProGet $(echo "scale=1; $akb/1000000" | bc) MB, ProGet -> pixi $(echo "scale=1; $pgb/1000000" | bc) MB)" "$(px_tail 2)"
done
ev "ProGet -> AK auth: $(podman logs --since 10m ak-conda-caddy 2>&1 | grep '"uri"' | jq -r 'select((.request.headers["User-Agent"]//[""])[0]|startswith("ProGet")) | .status' | sort | uniq -c | tr -s ' \n' ' ') (no 401: basic auth is sent pre-emptively)"
# 2. lockfile
[[ $(sha256sum < "$D/pixi.lock") == "$lock0" ]]; check $? "2: pixi.lock unchanged by install --locked through ProGet (keeps the https://ak.internal URLs)"

# 3. name ownership
note "3. name ownership: scn-virtual through ProGet (feed ak-scn-virtual)"
vers() { jq -c '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name=="acme-core") | .version] | unique'; }
akget "$(consumer_tok)" conda/conda-internal/noarch/repodata.json >/dev/null; hosted=$(vers < "$WORK/last.body")
top=$(jq -r 'sort_by(split(".") | map(tonumber? // .)) | last' <<<"$hosted")
akget "$SCN_TOKENS/scn-reader.token" conda/conda-fake-upstream/noarch/repodata.json >/dev/null; fake=$(vers < "$WORK/last.body")
r=$(akget "$SCN_TOKENS/scn-reader.token" conda/scn-virtual/channeldata.json); ev "AK scn-virtual/channeldata.json: HTTP $r: $(head -c 170 "$WORK/last.body")"
fu_channeldata > "$WORK/fcd.txt"; ev "workaround: the fake upstream gets a channeldata.json for this run: $(<"$WORK/fcd.txt")"
ev "ak-scn-virtual index: $(pg_reindex ak-scn-virtual ak-scn-virtual)"
r=$(pgget ak-scn-virtual noarch/repodata.json); via=$(vers < "$WORK/last.body")
ev "conda-internal acme-core: $hosted; fake upstream alone: $fake; scn-virtual through ProGet: $via (noarch: $r)"
[[ "$fake" == *99.0.0* && "$via" == "$hosted" ]]; check $? "3: scn-virtual through ProGet offers only the hosted acme-core $via (99.0.0 dropped by AK's name guard)" "offers $via"
G="$WORK/s1p/guard"; rm -rf "$G"; mkdir -p "$G"
printf '[workspace]\nname = "s1-guard"\nchannels = ["https://ak.internal/conda/scn-virtual"]\nplatforms = ["linux-64"]\nchannel-priority = "strict"\n[dependencies]\npython = "3.12.*"\nacme-core = "*"\n' > "$G/pixi.toml"
PX_AUTH="$SCN_TOKENS/scn-reader-auth.json" px proget "$G" new:scn-s1p-guard lock; got=$(lock_version "$G" acme-core)
ev "unpinned solve through ProGet: exit $PX_RC, ${PX_S} s, acme-core ${got:-none}"
[[ "$got" == "$top" ]]; check $? "3: unpinned 'acme-core = \"*\"' solved through ProGet locks the hosted $got, not 99.0.0" "${got:-$(px_tail 2)}"

# 4. fresh solve, rewritten records
note "4. a fresh solve through ProGet; the records ProGet rewrites"
akget "$(consumer_tok)" conda/conda-virtual/noarch/repodata.json >/dev/null; mv "$WORK/last.body" "$SCN_OUT/s1p-ak-noarch.json"
pgget ak-virtual noarch/repodata.json >/dev/null; mv "$WORK/last.body" "$SCN_OUT/s1p-pg-noarch.json"
fid=$(python3 -I - "$SCN_OUT/s1p-ak-noarch.json" "$SCN_OUT/s1p-pg-noarch.json" <<'PY'
import json, sys, collections
a, b = (json.load(open(f)) for f in sys.argv[1:3])
n = miss = 0; c = collections.Counter(); gone = []
for sec in ("packages", "packages.conda"):
    A, B = a.get(sec, {}), b.get(sec, {})
    n += len(A); gone += sorted(set(A) - set(B))
    for k in set(A) & set(B):
        for f in ("noarch", "track_features", "license_family"):
            if f in A[k] and f not in B[k]: c[f] += 1
print(f"{n} records from AK, {len(gone)} missing through ProGet ({', '.join(gone[:5])}); fields dropped: " + ", ".join(f"{f} x{v}" for f, v in c.items()))
PY
)
ev "4. noarch/repodata.json AK vs ProGet: $fid"
ev "4. info: AK $(jq -c .info "$SCN_OUT/s1p-ak-noarch.json"), ProGet $(jq -c .info "$SCN_OUT/s1p-pg-noarch.json")"
C="$WORK/s1p/solve"; project_copy "$C" conda-only; rm -f "$C/pixi.lock"; t=$(date +%s)
px proget "$C" new:scn-s1p-4 lock; lrc=$PX_RC; ls=$PX_S
ev "4. fresh solve (conda-only copy, cold client): exit $lrc, ${ls} s; ProGet served: $(podman logs --since "$(date -u -d "@$t" +%FT%TZ)" scn-proget 2>&1 | grep -oE 'GET http://scn-proget/conda/ak-virtual/[^ ]*repodata[^ ]* - [0-9]+ [0-9]+ [^ ]+ [0-9.]+ms' | sed -E 's|GET http://scn-proget/conda/ak-virtual/||' | awk '{printf "%s %s %.1f MB %.1f s; ", $1, $3, $4/1e6, $6/1000}')"
nf=$(grep -c 'noarch: false' "$C/pixi.lock"); rm -rf "$C/.pixi"
px proget "$C" new:scn-s1p-4 install --locked; irc=$PX_RC
px proget "$C" scn-s1p-4 run python -c 'import typing_extensions; print("import ok")'; imp=$(grep -c 'import ok' "$PX_OUT")
ev "4. the ProGet-solved lock: $nf records say 'noarch: false' (an AK-solved lock has none); install exit $irc; import typing_extensions (noarch: python): $( ((imp)) && echo ok || px_tail 2)"
[[ $lrc == 0 && $irc == 0 && $imp == 1 ]]; check $? "4: a fresh solve through ProGet works (${ls} s) and installs, though ProGet drops 'noarch' from every record ($nf lock entries say noarch: false; rattler links them as noarch from the package itself)" "lock $lrc install $irc import $imp"

# 5. allowlist propagation, untouched
note "5. allowlist on: propagation through ProGet's local index (no intervention)"
pg_feed s1-fresh ak-virtual
r=$(pgget ak-virtual "$OUTSIDE_FILE"); ev "5. $OUTSIDE downloaded once through the long-lived feed ak-virtual (now cached there): HTTP ${r%% *}"
pgget s1-fresh noarch/repodata.json >/dev/null; ev "5. t=0- fresh feed: $OUTSIDE records $(recs "$OUTSIDE" < "$WORK/last.body"); index age $(( $(date +%s) - $(pg_index ak-virtual | cut -d' ' -f2) )) s"
t_on=$(date +%s); ev "5. allowlist ON: $(al_on_from_lock)"
P="$WORK/s1p/add"; project_copy "$P"; px proget "$P" new:scn-s1p-add-early add --no-install "$OUTSIDE"
early=$(grep -oE "Added ${OUTSIDE}[^ ]* [^ ]*" "$PX_OUT" | head -1)
ev "5. t=+$(( $(date +%s) - t_on ))s pixi add $OUTSIDE through ProGet: exit $PX_RC: ${early:-$(px_msg)}"
pg_wait_listing s1-fresh "$OUTSIDE" absent >/dev/null; wrc=$?; seen=$(( $(date +%s) - t_on ))
ev "5. t=+${seen}s the fresh feed lists $OUTSIDE x0 (polled every 30 s with a plain GET of noarch/repodata.json); index written $(date -u -d "@$(pg_index ak-virtual | cut -d' ' -f2)" +%T)"
ev "5. ProGet -> AK since allowlist ON: $(pg_upstream_since "$t_on" json)"
if [[ $wrc == 0 ]]; then check 0 "5: the allowlist reaches ProGet clients ${seen} s after it is set, with nobody touching ProGet (index refreshed on a request once ~10 min old, then rebuilt)"
else fail "5: the allowlist reaches ProGet clients within ${PG_PROPAGATION_MAX_S:-2400} s" "index never replaced with a filtered one"; fi
[[ -n $early ]]; check $? "5: inside the window, pixi add $OUTSIDE through ProGet still succeeds from the old index (\"$early\")" "$(px_msg)"
CF=$(pg_config s1-fresh); project_copy "$P"; px "$CF" "$P" new:scn-s1p-add-late add --no-install "$OUTSIDE"; msg=$(px_msg)
ev "5. after propagation, pixi add $OUTSIDE through a fresh feed: exit $PX_RC: $msg"
[[ $PX_RC != 0 && $msg == "No candidates were found for $OUTSIDE"* ]]; check $? "5: after propagation, pixi add $OUTSIDE through ProGet fails: \"$msg\"" "exit $PX_RC $(px_tail 2)"
r=$(pgget s1-fresh "$OUTSIDE_FILE"); ev "5. download $OUTSIDE_FILE through the fresh feed: HTTP $r: $(head -c 120 "$WORK/last.body")"
[[ ${r%% *} == 404 ]]; check $? "5: download of $OUTSIDE through a feed that never cached it is 404" "HTTP $r"
pgget ak-virtual noarch/repodata.json >/dev/null; nc=$(recs "$OUTSIDE" < "$WORK/last.body"); r=$(pgget ak-virtual "$OUTSIDE_FILE")
project_copy "$P"; px proget "$P" new:scn-s1p-add-cached add --no-install "$OUTSIDE"; cached=$(grep -oE "Added ${OUTSIDE}[^ ]* [^ ]*" "$PX_OUT" | head -1)
ev "5. the feed that cached $OUTSIDE: lists it x$nc, download HTTP ${r%% *}, pixi add: exit $PX_RC: ${cached:-$(px_msg)}"
[[ $nc -gt 0 && ${r%% *} == 200 && -n $cached ]]; check $? "5 caveat: a feed that cached $OUTSIDE before the allowlist keeps listing it ($nc records) and serving it, so pixi add still works there (\"$cached\"): ProGet merges cached packages into the feed's index" "listed $nc, HTTP $r, pixi exit $PX_RC: $(px_msg)"
