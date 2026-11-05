#!/usr/bin/env bash
# G7 Zero egress: since make disconnect, while the site did everything G4-G6 did, nothing left.
#   G7a  no route out from any container: the stack, the ledger, llama-server (a probe runs in
#        each container's own network namespace)
#   G7b  the egress ledger gained no line
#   G7c  the cache answered: hits on the Remotes the site used, no miss that went upstream
#   G7d  no UPSTREAM_FETCHED row and no MCP_MIRROR_SYNCED row since the disconnect
#   G7e  the inventory read on the site is the seed's, item for item and hash for hash
# and, last, the control: a hole is poked (one Remote online for one request) and the attempt
# shows up in the ledger and the audit log; sealed again, the same request adds nothing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_site
G=G7
at=$(jq -r .at "$DISC"); l_at=$(jq -r .ledger_lines "$DISC")
pyimg="$P/oci-dockerhub/$(manifest '.image[] | select(.name == "python") | .ref')"
echo "disconnected at $at (ledger had $l_at lines)"

# --- G7a ---------------------------------------------------------------------------------
probe='
import socket, sys
out = []
for host, port in (("1.1.1.1", 443), ("8.8.8.8", 53), ("huggingface.co", 443), ("registry-1.docker.io", 443), ("pypi.org", 443)):
    try:
        socket.create_connection((host, port), timeout=4).close(); out.append(host + " REACHABLE")
    except OSError as e:
        out.append(host + " " + type(e).__name__)
print("; ".join(out)); sys.exit(1 if any("REACHABLE" in x for x in out) else 0)'
bad="" n=0
for c in $(podman ps --format '{{.Names}}' | grep "^$PROJECT-" | sort); do
  n=$((n + 1))
  r=$(podman run --rm --network "container:$c" "$pyimg" python -I -c "$probe" 2>&1); rc=$?
  printf '  %-28s %s\n' "$c" "$r"
  (( rc == 0 )) || bad+="$c "
done
check G7a "no route out from any of the $n running containers (stack, ledger, llama-server)" "reachable from: $bad" \
  test -z "$bad" -a "$n" -gt 5

# --- G7b ---------------------------------------------------------------------------------
# leave out the control windows of earlier runs of this gate (out/gates/control-windows.tsv)
WIN=$(jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))' "$GOUT/control-windows.tsv" 2>/dev/null || echo '[]')
# timestamps compared to the second (audit rows carry microseconds, the ledger does not)
in_control='def inctl: .[0:19] as $t | any($w[]; $t >= .[0][0:19] and $t <= .[1][0:19]);'
new=$(jq -c --arg t "$at" --argjson w "$WIN" "$in_control"' select(.t >= $t and .event == "open" and (.t | inctl | not))' "$LEDGER_FILE" | wc -l)
total=$(ledger_lines)
echo "ledger: $l_at connections at the disconnect, $total now; opened since then, outside control windows: $new"
jq -c --arg t "$at" --argjson w "$WIN" "$in_control"' select(.t >= $t and .event == "open" and (.t | inctl | not))' "$LEDGER_FILE" | head -5
check G7b "the egress ledger saw no connection opened since the disconnect" "$new connections" test "$new" -eq 0

# --- G7c ---------------------------------------------------------------------------------
call admin GET /api/v1/admin/metrics > "$GOUT/g7-metrics.txt"
grep -E '^ak_proxy_cache_lookups_total\{' "$GOUT/g7-metrics.txt" | sort | tee "$GOUT/g7-lookups.txt"
used=(oci-ghcr oci-dockerhub pypi-remote npm-remote plugins)
nohit=""
for r in "${used[@]}"; do
  h=$(metric ak_proxy_cache_lookups_total "repository=\"$r\",result=\"hit\"")
  (( h > 0 )) || nohit+="$r "
done
check G7c "the Remotes the site used answered from the cache (hit > 0: ${used[*]})" "no hits on: $nohit" test -z "$nohit"
# A cache-only miss counts twice: as a cache lookup `miss`, then as `cache_only_miss` at the
# upstream gate, where it ends. Every miss on a cache-only Remote must have ended there.
leak=""
for r in "${REMOTES[@]}"; do
  m=$(grep -E "^ak_proxy_cache_lookups_total\{repository=\"$r\",result=\"miss[^\"]*\"\}" "$GOUT/g7-lookups.txt" | awk '{s += $2} END {print s + 0}')
  c=$(metric ak_proxy_cache_lookups_total "repository=\"$r\",result=\"cache_only_miss\"")
  (( m <= c )) || leak+="$r(miss $m, cache_only_miss $c) "
done
check G7c "every cache miss on a cache-only Remote ended at the cache-only gate (miss <= cache_only_miss)" "$leak" test -z "$leak"
stale=$(metric ak_proxy_stale_if_error_responses_total "")
check G7c "nothing was served stale (ak_proxy_stale_if_error_responses_total is 0)" "$stale" test "$stale" -eq 0

# --- G7d ---------------------------------------------------------------------------------
audit_items UPSTREAM_FETCHED "$at" | jq -c --argjson w "$WIN" "$in_control"' select(.created_at | inctl | not)' > "$GOUT/g7-upstream-fetched.jsonl"
audit_items MCP_MIRROR_SYNCED "$at" > "$GOUT/g7-mcp-synced.jsonl"
echo "since $at: UPSTREAM_FETCHED $(wc -l < "$GOUT/g7-upstream-fetched.jsonl") (outside control windows), MCP_MIRROR_SYNCED $(wc -l < "$GOUT/g7-mcp-synced.jsonl")"
head -3 "$GOUT/g7-upstream-fetched.jsonl"
check G7d "no UPSTREAM_FETCHED audit row since the disconnect" "$(wc -l < "$GOUT/g7-upstream-fetched.jsonl") rows" \
  test ! -s "$GOUT/g7-upstream-fetched.jsonl"
check G7d "no MCP_MIRROR_SYNCED row since the disconnect (the MCP Remote sync is paused)" "$(wc -l < "$GOUT/g7-mcp-synced.jsonl") rows" \
  test ! -s "$GOUT/g7-mcp-synced.jsonl"

# --- G7e ---------------------------------------------------------------------------------
"$ROOT/seed/inventory.sh" site
diff <(cut -f1-3 "$ROOT/out/inventory/seed.tsv") <(cut -f1-3 "$ROOT/out/inventory/site.tsv") > "$GOUT/g7-inventory.diff"
echo "inventory diff (kind, name, sha256): $(wc -l < "$GOUT/g7-inventory.diff") lines"; head -10 "$GOUT/g7-inventory.diff"
check G7e "the site serves exactly the seeded inventory ($(wc -l < "$ROOT/out/inventory/site.tsv") items, same SHA-256 each)" \
  "$(wc -l < "$GOUT/g7-inventory.diff") diff lines (out/gates/g7-inventory.diff)" \
  bash -c "[[ ! -s '$GOUT/g7-inventory.diff' ]] && ! cut -f3 '$ROOT/out/inventory/site.tsv' | grep -qx -- -"

# --- the control: poke a hole, then seal it again ----------------------------------------
# A quiet ledger and an empty audit log prove something only if they would have caught an
# attempt. pypi-remote is put back online for one request for a package nobody seeded: that
# request does try to leave (and fails: there is no route), and it must show up in the ledger
# and as an UPSTREAM_FETCHED row. Then pypi-remote is cache-only again and the same request
# must add nothing. The control's window is recorded in out/gates/control-windows.tsv, and
# G7b and G7d leave out exactly those windows when the gate is run again.
PKG=offgrid-control-$RANDOM
cs=$(date -u +%FT%TZ); c0=$(ledger_lines)
api PUT /repositories/pypi-remote/upstream-mode -d '{"upstream_mode":"online"}' >/dev/null
echo "control: pypi-remote upstream-mode online: HTTP $(code)"
ms=$(ms_of call developer GET "/pypi/pypi-remote/simple/$PKG/" -o /dev/null)
echo "control: GET /pypi/pypi-remote/simple/$PKG/ (online) -> HTTP $(code) in $ms ms"
sleep 3
c1=$(ledger_lines)
jq -c --arg t "$cs" 'select(.t >= $t)' "$LEDGER_FILE" | tail -2
f1=$(audit_items UPSTREAM_FETCHED "$cs" 2 | jq -c 'select(.details.repository == "pypi-remote")' | tee "$GOUT/g7-control-rows.jsonl" | wc -l)
head -1 "$GOUT/g7-control-rows.jsonl" | jq -c '{action, details: (.details | {repository, host, path, result, error_type, status})}'
api PUT /repositories/pypi-remote/upstream-mode -d '{"upstream_mode":"cache_only"}' >/dev/null
echo "control: pypi-remote upstream-mode cache_only again: HTTP $(code) $(jq -c '{effective_upstream_mode}' "$FOUT/.body")"
sealed=$(date -u +%FT%TZ)
ms2=$(ms_of call developer GET "/pypi/pypi-remote/simple/$PKG/" -o /dev/null); sealed_code=$(code)
echo "control: the same GET (sealed) -> HTTP $sealed_code in $ms2 ms"
sleep 3
c2=$(ledger_lines)
f2=$(audit_items UPSTREAM_FETCHED "$sealed" 2 | wc -l)
ce=$(date -u +%FT%TZ)
printf '%s\t%s\n' "$cs" "$sealed" >> "$GOUT/control-windows.tsv"
echo "control: ledger connections $c0 -> $c1 (hole) -> $c2 (sealed); UPSTREAM_FETCHED rows: $f1 in the hole, $f2 after sealing"
check G7 "control: with the hole poked, the attempt to leave is in the ledger" "ledger $c0 -> $c1" test "$c1" -gt "$c0"
check G7 "control: with the hole poked, the attempt is an UPSTREAM_FETCHED row" "$f1 rows" test "$f1" -gt 0
check G7 "control: sealed again, the same request adds no ledger line and no audit row, and is a 404" \
  "ledger $c1 -> $c2, rows $f2, HTTP $sealed_code" bash -c "[[ $c2 -eq $c1 && $f2 -eq 0 && $sealed_code == 404 ]]"
