#!/usr/bin/env bash
# Stop Artifact Keeper. Pass -v to also delete volumes (all data!).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$HERE/.env.example"
podman compose --env-file "$ENV_FILE" -p artifact-keeper \
  -f "$HERE/compose/docker-compose.yml" \
  -f "$HERE/compose/compose.override.yml" down "$@"
