#!/usr/bin/env bash
# S3 curated-channel-down, ProGet: Artifact Keeper itself is down (ak-conda-backend stopped
# for OUTAGE_S, default 90 s, with the registry's compose helper); ProGet Free is in front.
# The outage is timed so that ProGet's ak-virtual index turns ~10 minutes old during it (AK is
# stopped at 7 minutes), the age at which ProGet starts an update on the next client request.
#   1. install --locked of the conda-only copy of project/ (cold client) succeeds from the
#      feed's cached packages; project/ as is fails on its PyPI wheel (fetched from ak.internal)
#   2a a fresh solve while the index is younger than ~10 minutes: served from ProGet's index
#   2b (bad) once the index is past ~10 minutes, ProGet tries to update it on every request,
#      fails (AK 502), and answers metadata with HTTP 500 instead of the old index: the solve
#      fails (ProGet Free keeps no metadata to fall back on)
#   3. a package ProGet never fetched: the status and body
#   4. (bad) a forced update during the outage (Local Index > delete, the UI's troubleshooting
#      action): metadata 5xx until AK is back
#   5. backend started, healthy; ProGet's index rebuilt, a fresh pull works again
# The backend is started again by a trap, also on failure.
set -uo pipefail
AM=proget
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OUTAGE_S=${OUTAGE_S:-90}
scn_begin S3 curated-channel-down-proget "Artifact Keeper down for ${OUTAGE_S} s, ProGet Free in front"
[[ $(backend_health) == healthy ]] || { fail "setup" "ak-conda-backend is $(backend_health)"; exit 1; }
C="$WORK/s3p/conda-only"; D="$WORK/s3p/project"
NEVER=$(pick_uncached) || { fail "setup" "no uncached package found"; exit 1; }
ev "never fetched through ProGet or by AK: $NEVER"

note "warm-up: ProGet index and packages"
# a known starting point: the full index, rebuilt with the allowlist as found (an earlier
# scenario may have left ProGet holding an index built while the allowlist was on)
ev "ak-virtual index rebuilt (Local Index > delete), allowlist $(akapi GET /repositories/conda-virtual/allowlist | jq -c '{enabled}'): $(pg_reindex ak-virtual ak-virtual)"
project_copy "$C" conda-only; px proget "$C" new:scn-s3p-warm install --locked; ev "warm install --locked through ProGet: exit $PX_RC, ${PX_S} s"
# time the outage: stop AK when the index is 7 min old (an update in progress first finishes)
age=$(pg_index_age ak-virtual)
if (( age > 420 )); then
  ev "index is $age s old; letting ProGet update it first"
  m0=$(pg_index ak-virtual | cut -d' ' -f2); t1=$SECONDS
  while [[ $(pg_index ak-virtual | cut -d' ' -f2) == "$m0" ]] && (( SECONDS - t1 < 1500 )); do pgget ak-virtual noarch/repodata.json >/dev/null; sleep 20; done
  ev "index updated after $((SECONDS - t1)) s"; age=$(pg_index_age ak-virtual)
fi
(( age < 400 )) && { note "waiting $((400 - age)) s until the index is 6.7 min old"; sleep $((400 - age)); }
ev "ak-internal index refreshed so that it is not the one to go stale first: $(pg_reindex ak-internal ak-internal 300)"
age=$(pg_index_age ak-virtual); (( age < 420 )) && sleep $((420 - age))

guard backend '[[ $(backend_health) == healthy ]] || { compose start backend >/dev/null 2>&1; echo "   backend started by the trap, healthy after $(wait_backend_healthy 240) s"; }'
t_stop=$SECONDS; t_stop_u=$(date +%s); compose stop backend >/dev/null 2>&1
ev "ak-conda-backend stopped at $(date -u +%T) ($(podman inspect ak-conda-backend --format '{{.State.Status}}')); ProGet's ak-virtual index is $(pg_index_age ak-virtual) s old"
r=$(akget "$(consumer_tok)" conda/conda-virtual/noarch/repodata.json); ev "AK direct during the outage: GET conda-virtual/noarch/repodata.json: HTTP $r"

# 1. install --locked
project_copy "$C" conda-only; t=$(date +%s); px proget "$C" new:scn-s3p-1 install --locked
ev "1. ProGet: install --locked, conda-only (cold client): exit $PX_RC, ${PX_S} s; ProGet -> pixi: $(pg_served_since "$t")"
[[ $PX_RC == 0 ]]; check $? "1: install --locked through ProGet succeeds while Artifact Keeper is down (${PX_S} s, packages from the feed's cache)" "$(px_msg)"
project_copy "$D"; px proget "$D" new:scn-s3p-1b install --locked; msg=$(px_msg)
ev "1. ProGet: install --locked, project/ as is (PyPI from ak.internal): exit $PX_RC, ${PX_S} s: $msg"
[[ $PX_RC != 0 && $msg == *pypi-remote* ]]; check $? "1: project/ as is fails only on its PyPI wheel, which is fetched from ak.internal, not through ProGet: \"$msg\"" "exit $PX_RC $msg"

# 2a. fresh solve, index younger than ~10 min
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; t=$(date +%s); a0=$(pg_index_age ak-virtual)
px proget "$C" new:scn-s3p-2a lock
ev "2a. ProGet: fresh solve (cold client, AK down) started at index age ${a0} s: exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $PX_RC == 0 ]]; check $? "2a: a fresh solve through ProGet succeeds while AK is down and ProGet's index is younger than ~10 min (started at ${a0} s, ${PX_S} s)" "$(px_msg)"

# 2b. the index past its update age
w=$(( 640 - $(pg_index_age ak-virtual) )); (( w > 0 )) && { note "waiting ${w} s until the index is past 10 min"; sleep "$w"; }
t=$(date +%s); r=$(pgget ak-virtual noarch/repodata.json); body=$(head -c 120 "$WORK/last.body" | tr '\n' ' ')
ev "2b. index $(pg_index_age ak-virtual) s old; GET ak-virtual noarch/repodata.json: HTTP $r: $body"
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px proget "$C" new:scn-s3p-2b lock; msg=$(px_msg)
ev "2b. ProGet: fresh solve (cold client, AK down): exit $PX_RC, ${PX_S} s: $msg"
ev "2b. ProGet's update attempts while AK is down (Caddy): $(pg_upstream_since "$t" json)"
[[ ${r%% *} =~ ^5 && $PX_RC != 0 ]]; check $? "2b (bad): once its index is ~10 min old, ProGet answers metadata with HTTP ${r%% *} (\"$body\") while AK is down instead of serving the old index; the solve fails: \"$msg\"" "HTTP $r, solve exit $PX_RC"

# 3. never fetched
r=$(pgget ak-virtual "$NEVER"); body=$(head -c 160 "$WORK/last.body" | tr '\n' ' ')
ev "3. ProGet: GET $NEVER: HTTP $r: $body"
[[ ${r%% *} =~ ^(404|502|503)$ ]]; check $? "3: a package ProGet never fetched is refused while AK is down (HTTP ${r%% *}: $body)" "HTTP $r"

# 4. forced update while AK is down
pgui delete-index ak-virtual >/dev/null; sleep 5
r=$(pgget ak-virtual noarch/repodata.json)
ev "4. after Local Index > delete, AK down: GET ak-virtual noarch/repodata.json: HTTP $r: $(head -c 120 "$WORK/last.body"); UI: $(pgui index ak-virtual)"
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px proget "$C" new:scn-s3p-4 lock; msg=$(px_msg)
ev "4. fresh solve after the forced update: exit $PX_RC, ${PX_S} s: $msg"
[[ ${r%% *} =~ ^5 && $PX_RC != 0 ]]; check $? "4 (bad): after a forced index update while AK is down, ProGet answers metadata with HTTP ${r%% *} until AK is back and the solve fails: \"$msg\"" "HTTP $r, solve exit $PX_RC"

# 5. back
left=$(( OUTAGE_S - (SECONDS - t_stop) )); (( left > 0 )) && sleep "$left"
compose start backend >/dev/null 2>&1; t_start=$SECONDS
ev "5. backend started after $((t_start - t_stop)) s down; healthy after $(wait_backend_healthy 240) s ($(backend_health))"
w=$(pg_warm ak-virtual ak-virtual); ev "5. ProGet ak-virtual index back: $w"
r=$(pgget ak-virtual "$NEVER")
ev "5. ProGet: GET $NEVER: HTTP ${r%% *} ($((SECONDS - t_start)) s after the backend was started)"
[[ $(backend_health) == healthy && ${r%% *} == 200 ]]; check $? "5: after restart: backend healthy, ProGet's index rebuilt (${w%%,*}) and a fresh pull through ProGet works again" "health $(backend_health), HTTP $r"
