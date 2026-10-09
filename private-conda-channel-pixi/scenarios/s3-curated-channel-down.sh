#!/usr/bin/env bash
# S3 curated-channel-down: Artifact Keeper itself is down (ak-conda-backend stopped for
# OUTAGE_S, default 90 s, with the registry's compose helper); Nexus is in front.
#   1. through Nexus, cold client cache: pixi install --locked of the conda-only copy of
#      project/ succeeds; project/ as is fails on its PyPI wheel (fetched from ak.internal)
#   2. a fresh solve through Nexus with its metadata marked stale: served stale, or the message
#   3. a package Nexus never fetched: the status and body
#   4. backend started, healthy; a fresh pull through Nexus works again (and how long Nexus
#      takes to stop answering from its negative cache / auto-block)
# The backend is started again by a trap, also on failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
scn_begin S3 curated-channel-down "Artifact Keeper down for ${OUTAGE_S:-90} s, Nexus in front"
OUTAGE_S=${OUTAGE_S:-90}
[[ $(backend_health) == healthy ]] || { fail "setup" "ak-conda-backend is $(backend_health)"; exit 1; }
C="$WORK/s3/conda-only"; D="$WORK/s3/project"
NEVER=$(pick_uncached) || { fail "setup" "no uncached package found"; exit 1; }
ev "never fetched through Nexus or by AK: $NEVER"

note "warm-up: Nexus metadata and packages"
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px nexus "$C" new:scn-s3-warm lock; ev "warm solve through Nexus: exit $PX_RC, ${PX_S} s"
project_copy "$C" conda-only; px nexus "$C" new:scn-s3-warm install --locked; ev "warm install --locked through Nexus: exit $PX_RC"

guard backend '[[ $(backend_health) == healthy ]] || { compose start backend >/dev/null 2>&1; echo "   backend started by the trap, healthy after $(wait_backend_healthy 240) s"; }'
t_stop=$SECONDS; compose stop backend >/dev/null 2>&1; ev "ak-conda-backend stopped at $(date -u +%T) ($(podman inspect ak-conda-backend --format '{{.State.Status}}'))"
r=$(akget "$(consumer_tok)" conda/conda-virtual/noarch/repodata.json); ev "AK direct during the outage: GET conda-virtual/noarch/repodata.json: HTTP $r"

# 1. install --locked through Nexus
project_copy "$C" conda-only; m=$(nx_mark); px nexus "$C" new:scn-s3-1 install --locked
ev "1. Nexus: install --locked, conda-only (cold client): exit $PX_RC, ${PX_S} s; Nexus -> pixi: $(nx_served_since "$m")"
[[ $PX_RC == 0 ]]; check $? "install --locked through Nexus succeeds while Artifact Keeper is down (${PX_S} s, 43 packages from Nexus's cache)" "$(px_msg)"
project_copy "$D"; px nexus "$D" new:scn-s3-1b install --locked; msg=$(px_msg)
ev "1. Nexus: install --locked, project/ as is (PyPI from ak.internal): exit $PX_RC, ${PX_S} s: $msg"
[[ $PX_RC != 0 && $msg == *pypi-remote* ]]; check $? "project/ as is fails only on its PyPI wheel, which is fetched from ak.internal, not through Nexus: \"$msg\"" "exit $PX_RC $msg"

# 2. fresh solve, Nexus metadata stale
echo "   $(nx_invalidate ak-virtual)"; echo "   $(nx_invalidate ak-internal)"
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px nexus "$C" new:scn-s3-2 lock
ev "2. Nexus: fresh solve (cold client, Nexus metadata invalidated, AK down): exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $PX_RC == 0 ]]; check $? "fresh solve through Nexus succeeds from Nexus's stale metadata while AK is down (${PX_S} s)" "$(px_msg)"

# 3. never fetched
r=$(nxget ak-virtual "$NEVER"); body=$(grep -oE 'Remote Auto Blocked[^<]*|<title>[^<]*' "$WORK/last.body" | head -2 | tr '\n' ' ')
ev "3. Nexus: GET $NEVER: HTTP $r: $body"
[[ ${r%% *} =~ ^(404|502|503)$ ]]; check $? "a package Nexus never fetched is refused while AK is down (HTTP ${r%% *}: $body)" "HTTP $r"

# 4. back
left=$(( OUTAGE_S - (SECONDS - t_stop) )); (( left > 0 )) && sleep "$left"
compose start backend >/dev/null 2>&1; t_start=$SECONDS
ev "4. backend started after $((t_start - t_stop)) s down; healthy after $(wait_backend_healthy 240) s ($(backend_health))"
r=$(akget "$(consumer_tok)" conda/conda-virtual/noarch/repodata.json.zst); ev "4. AK direct GET conda-virtual/noarch/repodata.json.zst: HTTP $r"
ok=1; t1=$SECONDS
while (( SECONDS - t1 < 300 )); do r=$(nxget ak-virtual "$NEVER"); [[ ${r%% *} == 200 ]] && { ok=0; break; }; sleep 10; done
ev "4. Nexus: GET $NEVER: HTTP ${r%% *} $((SECONDS - t1)) s after the backend was healthy (Nexus negative cache $(nxapi GET /v1/repositories/conda/proxy/ak-virtual | jq -r .negativeCache.timeToLive) min, auto-block)"
[[ $(backend_health) == healthy && $ok == 0 ]]; check $? "after restart: backend healthy, a fresh pull through Nexus works again ($((SECONDS - t1)) s after healthy)" "health $(backend_health), HTTP $r"
