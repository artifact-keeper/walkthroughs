#!/usr/bin/env bash
# S2 public-source-down, ProGet: conda-forge is unreachable from Artifact Keeper (its
# conda-forge remote is pointed at conda-forge.invalid), ProGet Free is warm in front.
# (What Artifact Keeper itself answers inside and after its cache TTL is S2's Nexus run;
# AK behaves the same whoever is in front.)
#   1. through ProGet, cold client cache: pixi install --locked succeeds
#   2. ProGet rebuilds its index during the block (Local Index > delete, so the rebuild is
#      certain): AK still serves the virtual's repodata from its own cache, the rebuild works
#   3. a fresh solve through ProGet during the block
#   4. a package nobody has cached: what ProGet answers
#   5. restored: upstream_url read back, the never-cached package pulls through ProGet
# The upstream URL is restored by a trap, also on failure.
set -uo pipefail
AM=proget
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scn_begin S2 public-source-down-proget "conda-forge unreachable from Artifact Keeper, ProGet Free warm"
BLACKHOLE=${BLACKHOLE:-https://conda-forge.invalid/conda-forge}
orig=$(akapi GET /repositories/conda-forge | jq -r .upstream_url)
[[ -n $orig && $orig != null && $orig != "$BLACKHOLE" ]] || { fail "setup" "conda-forge upstream_url is '$orig'"; exit 1; }
ev "conda-forge upstream_url before: $orig; AK conda-forge cache TTL $(akapi GET /repositories/conda-forge/cache-ttl | jq -r .cache_ttl_seconds) s"
setu() { akapi PATCH /repositories/conda-forge -o /dev/null -w '%{http_code}' -d "$(jq -nc --arg u "$1" '{upstream_url:$u}')"; }
guard conda-forge-upstream "forge_upstream_restore '$orig'"
D="$WORK/s2p/project"; C="$WORK/s2p/conda-only"
NEVER=$(pick_uncached) || { fail "setup" "no uncached package found"; exit 1; }
ev "never cached anywhere (AK proxy catalog 404): $NEVER"

note "warm-up: ProGet index and packages"
ev "ak-virtual index: $(pg_warm ak-virtual ak-virtual)"
project_copy "$D"; px proget "$D" new:scn-s2p-warm install --locked; ev "warm install --locked through ProGet: exit $PX_RC"

note "block: conda-forge -> $BLACKHOLE"
c=$(setu "$BLACKHOLE"); t_block=$(date +%s); ev "PATCH upstream_url=$BLACKHOLE: HTTP $c; read back $(akapi GET /repositories/conda-forge | jq -r .upstream_url)"
[[ $c == 200 ]] || { fail "block conda-forge" "PATCH HTTP $c"; exit 1; }

# 1. install --locked
project_copy "$D"; px proget "$D" new:scn-s2p-1 install --locked
ev "1. ProGet: install --locked (cold client): exit $PX_RC, ${PX_S} s: $(px_tail 1)"
[[ $PX_RC == 0 ]]; check $? "1: install --locked through ProGet succeeds with conda-forge unreachable from AK (${PX_S} s)" "$(px_msg)"

# 2. index rebuild during the block
w=$(pg_reindex ak-virtual ak-virtual); rc=$?
ev "2. ProGet ak-virtual index rebuilt during the block: $w"
[[ $rc == 0 ]]; check $? "2: ProGet rebuilds its index from AK during the block (${w%%;*}): AK serves the virtual's repodata from its own conda-forge cache" "$w"

# 3. fresh solve
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px proget "$C" new:scn-s2p-3 lock
ev "3. ProGet: fresh solve (cold client) during the block: exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $PX_RC == 0 ]]; check $? "3: a fresh solve through ProGet succeeds during the block (${PX_S} s)" "$(px_msg)"

# 4. never cached
r=$(pgget ak-virtual "$NEVER"); body=$(head -c 160 "$WORK/last.body" | tr '\n' ' ')
ra=$(akget "$(consumer_tok)" "conda/conda-virtual/$NEVER")
ev "4. never-cached $NEVER: ProGet HTTP $r: $body; AK direct HTTP $ra: $(head -c 120 "$WORK/last.body")"
[[ ${r%% *} =~ ^(404|502|503|504)$ ]]; check $? "4: a package nobody has cached fails through ProGet (HTTP ${r%% *}: $body)" "HTTP $r"
ev "ProGet -> AK during the block: $(pg_upstream_since "$t_block")"

# 5. restore
c=$(setu "$orig"); now=$(akapi GET /repositories/conda-forge | jq -r .upstream_url)
ev "5. PATCH upstream_url=$orig: HTTP $c; read back $now"
ok=1; t1=$SECONDS
while (( SECONDS - t1 < 300 )); do r=$(pgget ak-virtual "$NEVER"); [[ ${r%% *} == 200 ]] && { ok=0; break; }; sleep 10; done
ev "5. ProGet: GET $NEVER after restore: HTTP ${r%% *} after $((SECONDS - t1)) s"
[[ $now == "$orig" && $ok == 0 ]]; check $? "5: restored: upstream_url is $orig again and the never-cached package pulls through ProGet (HTTP ${r%% *}, $((SECONDS - t1)) s)" "upstream_url $now, HTTP $r"
