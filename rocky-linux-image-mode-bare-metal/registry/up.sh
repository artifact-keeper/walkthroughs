#!/usr/bin/env bash
# Start Artifact Keeper with rootless podman. Generates .env on first run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "up.sh: generating $ENV_FILE"
  umask 077
  jwt="$(openssl rand -base64 48 | tr -d '\n')"
  hook="$(openssl rand -base64 32 | tr -d '\n')"
  # alphanumeric only: safe in JSON, URLs, basic auth and shell without escaping
  admin="Ak$(openssl rand -hex 16)"
  sed -e "s|^JWT_SECRET=.*|JWT_SECRET=${jwt}|" \
      -e "s|^AK_WEBHOOK_SECRET_KEY=.*|AK_WEBHOOK_SECRET_KEY=${hook}|" \
      -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${admin}|" \
      "$HERE/.env.example" > "$ENV_FILE"
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
HTTP_PORT="${HTTP_PORT:-30080}"

compose() {
  podman compose --env-file "$ENV_FILE" -p artifact-keeper \
    -f "$HERE/compose/docker-compose.yml" \
    -f "$HERE/compose/compose.override.yml" "$@"
}

compose up -d

echo -n "up.sh: waiting for http://localhost:${HTTP_PORT}/readyz "
deadline=$((SECONDS + ${READY_TIMEOUT:-300}))
until curl -fsS "http://localhost:${HTTP_PORT}/readyz" >/dev/null 2>&1; do
  if (( SECONDS > deadline )); then
    echo; echo "up.sh: not ready after ${READY_TIMEOUT:-300}s; recent backend logs:" >&2
    podman logs --tail 50 artifact-keeper-backend >&2 || true
    exit 1
  fi
  echo -n "."; sleep 5
done
echo " ready"
curl -fsS "http://localhost:${HTTP_PORT}/readyz"; echo
