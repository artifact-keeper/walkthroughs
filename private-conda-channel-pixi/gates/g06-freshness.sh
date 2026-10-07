#!/usr/bin/env bash
# G6 Freshness and failure:
#   - an admin-set TTL on a remote conda channel: a package published upstream
#     is invisible while the cached repodata is fresh and appears once the TTL
#     has passed (staged with the fake upstream: acme-core 99.1.0 is added);
#   - the production proxy's TTL is reported;
#   - a virtual channel whose member cannot be fetched fails loudly (5xx), it
#     does not answer 200 with the member silently missing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G6; TTL=${TTL:-45}
"$GATES_DIR/fake-upstream.sh" up >/dev/null
ensure_repo conda-fake-upstream '{"key":"conda-fake-upstream","name":"gate: fake public upstream","format":"conda","repo_type":"remote","visibility":"internal","upstream_url":"http://fake-upstream:8000"}' || exit 1
http GET "$U/api/v1/repositories/conda-forge/cache-ttl" admin >/dev/null; echo "conda-forge proxy TTL: $(body)"
c=$(http PUT "$U/api/v1/repositories/conda-fake-upstream/cache-ttl" admin -H 'Content-Type: application/json' -d "{\"cache_ttl_seconds\":$TTL}"); echo "set TTL $TTL s on conda-fake-upstream: HTTP $c $(body)"
vers() { http GET "$U/conda/conda-fake-upstream/noarch/repodata.json" admin >/dev/null; body | jq -c '[.["packages.conda"][] | select(.name=="acme-core") | .version] | sort'; }
CH="$ROOT/out/fake-upstream"
# reset upstream to 99.0.0 only, warm the cache
rm -f "$CH"/noarch/acme-core-99.1.0-*.conda
"$GATES_DIR/fake-upstream.sh" up >/dev/null; sleep $((TTL + 5)); v0=$(vers); echo "t=0  cached: $v0"
# publish 99.1.0 upstream
ls "$ROOT"/out/fake-upstream-new/noarch/acme-core-99.1.0-*.conda >/dev/null 2>&1 || \
  OUT_DIR="$ROOT/out/fake-upstream-new" ACME_CORE_VERSION=99.1.0 "$ROOT/packages/build.sh" acme-core >/dev/null 2>&1
cp "$ROOT"/out/fake-upstream-new/noarch/acme-core-99.1.0-*.conda "$CH/noarch/"
"$GATES_DIR/fake-upstream.sh" up >/dev/null; t_pub=$SECONDS
v1=$(vers); echo "t=+$((SECONDS - t_pub))s after upstream publish: $v1"
until grep -q 99.1.0 <<<"$(vers)" || (( SECONDS - t_pub > TTL * 3 )); do sleep 5; done
v2=$(vers); dt=$((SECONDS - t_pub)); echo "t=+${dt}s: $v2"
if ! grep -q 99.1.0 <<<"$v1" && grep -q 99.1.0 <<<"$v2" && (( dt <= TTL + 15 )); then
  pass $G "new upstream package hidden while cached repodata is fresh, visible ${dt}s after publish (TTL ${TTL}s)"
elif grep -q 99.1.0 <<<"$v1"; then pass $G "new upstream package visible immediately (cache revalidated)"
else fail $G "new upstream package within TTL" "after ${dt}s: $v2"; fi
rm -f "$CH"/noarch/acme-core-99.1.0-*.conda; "$GATES_DIR/fake-upstream.sh" up >/dev/null

# broken member
ensure_repo conda-broken-upstream '{"key":"conda-broken-upstream","name":"gate: unreachable upstream","format":"conda","repo_type":"remote","visibility":"internal","upstream_url":"https://conda-upstream.invalid/conda-forge"}' || exit 1
ensure_repo conda-virtual-g6 '{"key":"conda-virtual-g6","name":"gate: virtual with a broken member","format":"conda","repo_type":"virtual","visibility":"internal","member_repos":[{"repo_key":"conda-internal","priority":1},{"repo_key":"conda-broken-upstream","priority":2}]}' || exit 1
c=$(http GET "$U/conda/conda-virtual-g6/noarch/repodata.json" admin); echo "virtual with unreachable member: HTTP $c $(body | head -c 200 | tr -d '\n')"
if [[ $c =~ ^5 ]]; then pass $G "virtual channel with an unreachable member fails loudly (HTTP $c)"
else blocked F3 $G "virtual channel with an unreachable member fails loudly" "HTTP $c with the member silently dropped"; fi
c=$(http GET "$U/conda/conda-virtual/linux-64/repodata.json" consumer); n=$(body | jq '(.["packages.conda"]|length) + (.packages|length)' 2>/dev/null)
echo "conda-virtual linux-64: HTTP $c, $n records"
if [[ $c == 200 && ${n:-0} -gt 1000 ]]; then pass $G "conda-virtual merges the conda-forge member ($n records)"
elif [[ $c =~ ^5 ]]; then pass $G "conda-virtual fails loudly when it cannot merge conda-forge (HTTP $c)"
else blocked F2,F3 $G "conda-virtual merges conda-forge or fails loudly" "HTTP $c with $n records (member over the 8 MiB fetch cap, dropped)"; fi
