#!/usr/bin/env bash
# What scanning does for agent plugins.
#  1. The scan results of a published zip (agent-plugins scans on upload).
#  2. The scan policy on agent-plugins (block_unscanned, block_on_fail, max_severity).
#  3. The hold, slowed down so you can look at it: a second repository, agent-plugins-staging,
#     has the same policy but scans only on request. A version published there is hidden
#     from every document and its download is 403 until its scan has run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S=agent-plugins-staging

say "1. scans of acme-review 1.0.0 in $REPO"
id=$(artifact_id "$REPO" acme-review/1.0.0/acme-review-1.0.0.zip)
echo "artifact id: $id"
adm "/api/v1/security/artifacts/$id/scans" | jq '[(if type=="array" then . else .items end)[] | {scan_type, status, findings_count, critical_count, high_count, started_at, completed_at}]'

say "2. the scan policy on $REPO"
adm /api/v1/security/policies | jq --arg r "$(adm "/api/v1/repositories/$REPO" | jq -r .id)" \
  '[(if type=="array" then . else .items end)[] | select(.repository_id == $r) | {name, max_severity, block_unscanned, block_on_fail, is_enabled}]'

say "3. the hold, in $S (scan on request)"
if [[ $(code GET "$U/api/v1/repositories/$S" admin) != 200 ]]; then
  adm /api/v1/repositories -X POST -H 'Content-Type: application/json' -d "{\"key\":\"$S\",\"name\":\"Agent plugins (staging: scanned on request)\",\"format\":\"agentplugins\",\"repo_type\":\"local\",\"visibility\":\"private\"}" | jq -c '{key,format,visibility}'
  adm "/api/v1/repositories/$S/security" -X PUT -H 'Content-Type: application/json' -d '{"scan_enabled":true,"scan_on_upload":false}' >/dev/null
  adm /api/v1/security/policies -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg r "$(adm "/api/v1/repositories/$S" | jq -r .id)" '{name:"agent-plugins-staging-hold",repository_id:$r,max_severity:"high",block_unscanned:true,block_on_fail:true}')" | jq -c '{name,block_unscanned}'
fi
v=$(date -u +1.0.%Y%m%d%H%M%S)   # a fresh version on every run: versions are immutable
"$RUN" -t admin -- ak agent plugins publish /plugins/acme-standards --repo "$S" --version "$v" >/dev/null 2>&1
echo "published acme-standards $v to $S"
echo "index.json:                $(code GET "$U/agentplugins/$S/acme-standards/index.json" admin) $(jq -c '{latest}' "$FOUT/.body" 2>/dev/null || true)"
echo "marketplace.json lists:    $(adm "/agentplugins/$S/marketplace.json" | jq -c '[.plugins[] | "\(.name)@\(.version)"]')"
echo "download $v:   HTTP $(code GET "$U/agentplugins/$S/$(zip_path acme-standards "$v")" admin)"
id=$(artifact_id "$S" "$(zip_path acme-standards "$v")")
adm /api/v1/security/scan -X POST -H 'Content-Type: application/json' -d "{\"artifact_id\":\"$id\"}" | jq -c . | head -c 300; echo
wait_listed "$S" acme-standards "$v"
echo "marketplace.json lists:    $(adm "/agentplugins/$S/marketplace.json" | jq -c '[.plugins[] | "\(.name)@\(.version)"]')"
echo "download $v:   HTTP $(code GET "$U/agentplugins/$S/$(zip_path acme-standards "$v")" admin)"
