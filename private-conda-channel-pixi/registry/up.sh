#!/usr/bin/env bash
# Start the ak-conda stack (rootless podman). Generates .env on first run,
# exports Caddy's internal root CA to out/ak-internal-ca.crt, waits for /readyz.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "up.sh: generating $ENV_FILE"
  umask 077
  jwt="$(openssl rand -base64 48 | tr -d '\n')"
  hook="$(openssl rand -base64 32 | tr -d '\n')"
  admin="Ak$(openssl rand -hex 16)"   # alphanumeric: safe everywhere
  sed -e "s|^JWT_SECRET=.*|JWT_SECRET=${jwt}|" \
      -e "s|^AK_WEBHOOK_SECRET_KEY=.*|AK_WEBHOOK_SECRET_KEY=${hook}|" \
      -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${admin}|" \
      "$REG_DIR/.env.example" > "$ENV_FILE"
  umask 022
fi
load_env
# Allow overriding the images from the caller's environment for one run
# (e.g. BACKEND_IMAGE=localhost/ak-backend:fix registry/up.sh) without editing .env.
export BACKEND_IMAGE="${AK_BACKEND_IMAGE:-$BACKEND_IMAGE}" WEB_IMAGE="${AK_WEB_IMAGE:-$WEB_IMAGE}"
echo "up.sh: backend=$BACKEND_IMAGE web=$WEB_IMAGE"

compose up -d

mkdir -p "$OUT"
echo -n "up.sh: waiting for Caddy's internal CA "
for _ in $(seq 60); do
  if podman exec ak-conda-caddy test -s /data/caddy/pki/authorities/local/root.crt 2>/dev/null; then break; fi
  echo -n "."; sleep 2
done
podman exec ak-conda-caddy cat /data/caddy/pki/authorities/local/root.crt > "$CA.tmp"
openssl x509 -in "$CA.tmp" -noout >/dev/null && mv "$CA.tmp" "$CA"
echo " $CA ($(openssl x509 -in "$CA" -noout -subject))"

echo -n "up.sh: waiting for $(AK_HOST_URL)/readyz "
deadline=$((SECONDS + ${READY_TIMEOUT:-300}))
until akcurl -fsS "$(AK_HOST_URL)/readyz" >/dev/null 2>&1; do
  if (( SECONDS > deadline )); then
    echo; echo "up.sh: not ready after ${READY_TIMEOUT:-300}s; backend logs:" >&2
    podman logs --tail 50 ak-conda-backend >&2 || true
    exit 1
  fi
  echo -n "."; sleep 5
done
echo " ready"
akcurl -fsS "$(AK_HOST_URL)/readyz"; echo
podman image inspect "$BACKEND_IMAGE" --format 'backend {{.Id}} rev={{index .Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true
