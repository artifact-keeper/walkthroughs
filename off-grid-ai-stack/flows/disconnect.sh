#!/usr/bin/env bash
# Step 4: cut the link. In order:
#   1. the scheduled upstream jobs paused (upstream_jobs_paused, #5317): MCP Remote sync,
#      curation sync, advisory re-evaluation, peer sync, the npm feed; a running sync finishes;
#   2. every Remote to cache-only (PUT .../upstream-mode, #5315): serve the cache, never ask
#      upstream, a clean 404 on a miss;
#   3. the configuration exported again (out/config/site.json);
#   4. the marks the zero-egress gates count from: the ledger's line count, the time, the
#      UPSTREAM_FETCHED and MCP_MIRROR_SYNCED row counts (out/disconnect.json);
#   5. the move: registry/out/phase says site, and every container of the stack is recreated
#      on ak-offgrid-site (compose.site.yml, internal: true), the ledger with it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [[ $(phase) == site ]]; then echo "disconnect: already on the site network"; exit 0; fi

say "1. pause the scheduled upstream jobs, and let a running MCP sync finish"
# Pause first: a sync already running when the Remotes go cache-only would end with errors
# and write its MCP_MIRROR_SYNCED row after the cut.
api PATCH /admin/settings/system -d '{"upstream_jobs_paused":true}' >/dev/null
echo "  PATCH /api/v1/admin/settings/system: HTTP $(code)"
api GET /admin/settings/system | jq -c '{upstream_jobs_paused, upstream_jobs_paused_source}'
for _ in $(seq 120); do
  api GET /repositories/mcp-official/mcp/sync >/dev/null
  jq -e '(.lastStartedAt == null) or (.lastFinishedAt != null and .lastFinishedAt >= .lastStartedAt)' "$FOUT/.body" >/dev/null && break
  sleep 5
done
echo "  mcp-official sync: $(jq -c '{lastStartedAt, lastFinishedAt}' "$FOUT/.body")"

say "2. every Remote to cache-only"
for r in "${REMOTES[@]}"; do
  api PUT "/repositories/$r/upstream-mode" -d '{"upstream_mode":"cache_only"}' >/dev/null
  printf '  %-14s HTTP %s %s\n' "$r" "$(code)" "$(jq -c '{upstream_mode, effective_upstream_mode}' "$FOUT/.body" 2>/dev/null || head -c 120 "$FOUT/.body")"
done

say "3. the configuration as it leaves the network"
mkdir -p "$ROOT/out/config"
api GET /admin/config/export > "$ROOT/out/config/site.json"
echo "  $(jq '.repositories | length' "$ROOT/out/config/site.json") repositories; the Remotes as exported:"
jq -c '.repositories[] | select(.repo_type == "remote") | {key, upstream_mode, cache_ttl_seconds, on_upstream_not_found, egress: .egress_proxy.mode}' "$ROOT/out/config/site.json"

say "4. the marks"
jq -n --arg t "$(date -u +%FT%TZ)" --argjson l "$(ledger_lines)" --argjson f "$(audit_count UPSTREAM_FETCHED)" \
  --argjson m "$(audit_count MCP_MIRROR_SYNCED)" \
  '{at: $t, ledger_lines: $l, upstream_fetched: $f, mcp_mirror_synced: $m}' | tee "$ROOT/out/disconnect.json"

say "5. move the stack to ak-offgrid-site (internal: no default route, no NAT (.1 is DNS only))"
# Take the stack down (volumes kept) and bring it up on the other network. compose can also
# move running containers by recreating them, but with podman the recreated containers lose
# their service-name DNS aliases (postgres, opensearch, ...) and the backend cannot find its
# database; created fresh they keep them. The ledger is not a compose service: it goes first,
# or compose cannot remove the seed network.
"$ROOT/ledger/down.sh"
"$ROOT/registry/down.sh"
echo site > "$PHASE_FILE"
"$ROOT/registry/up.sh"
"$ROOT/ledger/up.sh"
for c in $(podman ps --format '{{.Names}}' | grep "^$PROJECT-"); do
  printf '  %-28s %s\n' "$c" "$(podman inspect "$c" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
done
