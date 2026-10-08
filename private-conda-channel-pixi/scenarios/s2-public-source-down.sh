#!/usr/bin/env bash
# S2 public-source-down: conda-forge is unreachable from Artifact Keeper (its conda-forge
# remote is pointed at conda-forge.invalid), Nexus is warm.
#   1. through Nexus, cold client cache: pixi install --locked succeeds
#   2. straight to AK, twice: while AK's cached conda-forge index is still inside the remote's
#      cache TTL (300 s here), and again after the TTL has run out: what the virtual channel
#      answers (repodata, a package AK has cached, a package nobody has cached), and what
#      pixi install --locked and a fresh solve get
#   3. through Nexus: a fresh solve after Nexus revalidated its metadata during the block
#   4. restored: upstream_url read back, a never-cached package pulls again
# The upstream URL is restored by a trap, also on failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_secret SCN_NEXUS_ADMIN_PASSWORD
scn_begin S2 public-source-down "conda-forge unreachable from Artifact Keeper, Nexus warm"
BLACKHOLE=${BLACKHOLE:-https://conda-forge.invalid/conda-forge}
orig=$(akapi GET /repositories/conda-forge | jq -r .upstream_url)
[[ -n $orig && $orig != null && $orig != "$BLACKHOLE" ]] || { fail "setup" "conda-forge upstream_url is '$orig'"; exit 1; }
ev "conda-forge upstream_url before: $orig"
setu() { akapi PATCH /repositories/conda-forge -o /dev/null -w '%{http_code}' -d "$(jq -nc --arg u "$1" '{upstream_url:$u}')"; }
on_exit 'echo "   PATCH upstream_url back: HTTP $(setu "$orig"), now $(akapi GET /repositories/conda-forge | jq -r .upstream_url)"'
D="$WORK/s2/project"; C="$WORK/s2/conda-only"
NEVER=$(pick_uncached) || { fail "setup" "no uncached package found"; exit 1; }
CACHED=$(grep -m1 -oE '^- conda: https://ak.internal/conda/conda-virtual/noarch/[^ ]+' "$ROOT/project/pixi.lock" | sed -E 's|.*/conda-virtual/||')
TTL_S=$(akapi GET /repositories/conda-forge/cache-ttl | jq -r .cache_ttl_seconds)
ev "never cached anywhere (AK proxy catalog 404, no Nexus asset): $NEVER; cached in AK (from the lock): $CACHED"

note "warm-up: Nexus metadata and packages"
project_copy "$D"; px nexus "$D" new:scn-s2-warm install --locked; ev "warm install --locked through Nexus: exit $PX_RC"
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px nexus "$C" new:scn-s2-warm lock; ev "warm solve through Nexus: exit $PX_RC, ${PX_S} s"

note "block: conda-forge -> $BLACKHOLE"
c=$(setu "$BLACKHOLE"); t_block=$SECONDS; ev "PATCH upstream_url=$BLACKHOLE: HTTP $c; read back $(akapi GET /repositories/conda-forge | jq -r .upstream_url)"
[[ $c == 200 ]] || { fail "block conda-forge" "PATCH HTTP $c"; exit 1; }

# 1. through Nexus, cold client
project_copy "$D"; px nexus "$D" new:scn-s2-1 install --locked
ev "1. Nexus: install --locked (cold client): exit $PX_RC, ${PX_S} s: $(px_tail 1)"
[[ $PX_RC == 0 ]]; check $? "install --locked through Nexus succeeds with conda-forge unreachable (${PX_S} s, served from Nexus's cache)" "$(px_msg)"

# 2. straight to Artifact Keeper: inside AK's cache TTL, then after it
direct() { # PHASE
  local ph=$1 p r k
  for p in noarch/repodata.json linux-64/repodata.json.zst channeldata.json "$CACHED" "$NEVER"; do
    r=$(akget "$(consumer_tok)" "conda/conda-virtual/$p"); k=$(tr -c 'a-zA-Z0-9\n' _ <<<"$p")
    ev "2$ph. AK direct GET conda-virtual/$p: HTTP $r$( [[ ${r%% *} != 200 ]] && echo " $(head -c 160 "$WORK/last.body")")"
    printf -v "R${ph}_$k" '%s' "${r%% *}"
  done
  r=$(akget "$(consumer_tok)" "conda/conda-forge/noarch/repodata.json"); ev "2$ph. AK direct GET conda-forge/noarch/repodata.json (the remote itself): HTTP $r"
  ev "2$ph. response headers, conda-virtual/channeldata.json: $(akcurl -sS -o /dev/null -D - -H "Authorization: Bearer $(<"$(consumer_tok)")" "$U/conda/conda-virtual/channeldata.json" | tr -d '\r' | grep -iE '^(cache-control|age|warning|etag|last-modified|x-ak[^:]*):' | tr '\n' ' ')"
  project_copy "$D"; px ak "$D" "new:scn-s2-2$ph" install --locked
  ev "2$ph. AK direct: install --locked (cold client): exit $PX_RC, ${PX_S} s: $( [[ $PX_RC == 0 ]] && px_tail 1 || px_msg)"
  printf -v "RC${ph}_install" '%s' "$PX_RC"
  project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px ak "$C" "new:scn-s2-2${ph}s" lock
  ev "2$ph. AK direct: fresh solve (cold client): exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
  printf -v "RC${ph}_solve" '%s' "$PX_RC"
}
ev "AK conda-forge cache TTL: ${TTL_S} s"
direct a
left=$(( TTL_S + 15 - (SECONDS - t_block) )); (( left > 0 )) && { note "waiting ${left} s until AK's cached conda-forge index is older than its TTL"; sleep "$left"; }
ev "block has lasted $((SECONDS - t_block)) s (TTL ${TTL_S} s)"
direct b
NK=$(tr -c 'a-zA-Z0-9\n' _ <<<"$NEVER"); CK=$(tr -c 'a-zA-Z0-9\n' _ <<<"$CACHED")
for ph in a b; do
  when=$([[ $ph == a ]] && echo "inside AK's cache TTL" || echo "after AK's cache TTL")
  v="RC${ph}_install"; [[ ${!v} == 0 ]]; check $? "AK direct, $when: install --locked succeeds (packages from AK's own proxy cache)" "exit ${!v}"
  v="R${ph}_$CK"; [[ ${!v} == 200 ]]; check $? "AK direct, $when: a package AK has cached is served by URL ($CACHED: HTTP ${!v})" "HTTP ${!v}"
  v="R${ph}_$NK"; [[ ${!v} =~ ^(404|502|503|504)$ ]]; check $? "AK direct, $when: a package nobody has cached fails ($NEVER: HTTP ${!v})" "HTTP ${!v}"
  v="R${ph}_noarch_repodata_json"; s="RC${ph}_solve"
  if [[ ${!v} == 200 ]]; then pass "AK direct, $when: virtual repodata is served from AK's cached conda-forge index (HTTP 200; fresh solve exit ${!s})"
  elif [[ ${!v} =~ ^5 ]]; then pass "AK direct, $when: virtual repodata fails loudly (HTTP ${!v}) instead of answering without conda-forge (fresh solve exit ${!s})"
  else fail "AK direct, $when: virtual repodata is 200 from cache or a loud 5xx" "HTTP ${!v}"; fi
done

# 3. through Nexus, after Nexus revalidated during the block
echo "   $(nx_invalidate ak-virtual)"
project_copy "$C" conda-only; rm -f "$C/pixi.lock"; px nexus "$C" new:scn-s2-3 lock
ev "3. Nexus: fresh solve (cold client, Nexus metadata invalidated during the block): exit $PX_RC, ${PX_S} s$( [[ $PX_RC != 0 ]] && echo ": $(px_msg)")"
[[ $PX_RC == 0 ]]; check $? "fresh solve through Nexus succeeds during the block (${PX_S} s)" "$(px_msg)"
r=$(nxget ak-virtual "$NEVER"); ev "3. Nexus: never-cached $NEVER: HTTP $r"

# 4. restore
c=$(setu "$orig"); now=$(akapi GET /repositories/conda-forge | jq -r .upstream_url)
ev "4. PATCH upstream_url=$orig: HTTP $c; read back $now"
r=$(akget "$(consumer_tok)" "conda/conda-virtual/$NEVER")
ev "4. AK direct GET conda-virtual/$NEVER after restore: HTTP $r"
[[ $now == "$orig" && ${r%% *} == 200 ]]; check $? "restored: upstream_url is $orig again and a never-cached package pulls (HTTP ${r%% *})" "upstream_url $now, HTTP $r"
