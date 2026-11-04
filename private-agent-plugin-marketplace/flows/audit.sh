#!/usr/bin/env bash
# The audit trail through the REST API, for acme-review:
#   - who published each version: the artifact record (uploaded_by, created_at, sha256)
#   - every download: user, client address, user agent, time (download statistics)
#   - the audit log's events about the repository's tokens and permissions
# Agent Plugins publishes do not write an ARTIFACT_UPLOADED audit event on this build (the
# generic upload does); the artifact record is where the publisher is kept. See findings.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rid=$(adm "/api/v1/repositories/$REPO" | jq -r .id)
for v in 1.0.0 1.1.0; do
  id=$(artifact_id "$REPO" "$(zip_path acme-review "$v")")
  say "acme-review $v"
  echo "published:"
  adm "/api/v1/artifacts/$id" | jq -c '{at: .created_at, by: .uploaded_by_username, sha256: .checksum_sha256, harnesses: .metadata.harnesses, downloads: .download_count}'
  echo "downloads:"
  adm "/api/v1/admin/downloads?artifact_id=$id&per_page=50" | jq -c \
    '.downloads[] | {at: .downloaded_at, user: (.username // "anonymous"), ip: .ip_address, agent: (.user_agent // "-")}'
done
say "downloads from $REPO, by user and client"
adm "/api/v1/admin/downloads?repository_id=$rid&per_page=200" | jq -c \
  '[.downloads[] | {user: (.username // "anonymous"), agent: (.user_agent // "-")}] | group_by(.) | map(.[0] + {downloads: length}) | .[]'
say "audit events: tokens, users and permissions"
adm "/api/v1/admin/audit?per_page=200" | jq -c \
  '.items[] | select(.action | test("TOKEN|PERMISSION|USER_CREATED|REPOSITORY")) | {at: .created_at, actor: .actor_username, action, resource_type}' | tac
say "audit events for the version itself (none: see findings.md)"
id=$(artifact_id "$REPO" "$(zip_path acme-review 1.1.0)")
adm "/api/v1/admin/audit?resource_id=$id" | jq -c '{total}'
