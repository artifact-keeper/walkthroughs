#!/usr/bin/env bash
# The scan policy quarantined the vendored package when its upload scan found the findings
# (the scanner writes the hold without a recorded source). Acknowledging the findings makes
# the policy pass, but the hold itself stays until an administrator releases it:
# POST /api/v1/quarantine/{artifact_id}/release. Then the download is allowed.
#
#   exception/release.sh ["reason"]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../policy/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
reason=${1:-"findings acknowledged, ticket SEC-421"}
art=$(cat "$ROOT/out/vendored-artifact-id")
echo "release: before: $(body_of "$(api GET "/quarantine/$art")" | jq -c '{quarantine_status, is_blocked}')"
r=$(api POST "/quarantine/$art/release" -d "$(jq -nc --arg r "$reason" '{reason:$r}')"); must "release $art" "$r"
echo "release: $(body_of "$r" | jq -c .)"
echo "release: after:  $(body_of "$(api GET "/quarantine/$art")" | jq -c '{quarantine_status, is_blocked}')"
echo "release: download through npm-internal: HTTP $(akcurl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN" "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")"
echo "release: npm-internal score: $(body_of "$(api GET /repositories/npm-internal/security)" | jq -c '.score | {grade, grade_status, score, coverage, acknowledged_count}')"
