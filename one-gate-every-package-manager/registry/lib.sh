# Shared helpers for the ak-gate scripts. Source it; do not run it.
# Defines: REG_DIR, ENV_FILE, OUT, CA, TOKENS, AK_HOST, AK_URL, NET, compose(), akcurl(),
# AK_HOST_URL(), admin_token(); load_env() also sets HTTPS_PORT and AK_NET_SUBNET.
REG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REG_DIR/.env"
OUT="$REG_DIR/out"
CA="$OUT/ak-internal-ca.crt"
TOKENS="$REG_DIR/.tokens"
AK_HOST=ak.internal
AK_URL="https://$AK_HOST"
NET=ak-gate-net
PROJECT=ak-gate

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE missing; run registry/up.sh first" >&2; return 1; }
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  HTTPS_PORT="${HTTPS_PORT:-30446}"
  AK_NET_SUBNET="${AK_NET_SUBNET:-172.31.60.0/24}"
  export HTTPS_PORT AK_NET_SUBNET
}

compose() {
  podman compose --env-file "$ENV_FILE" -p "$PROJECT" \
    -f "$REG_DIR/compose/docker-compose.yml" \
    -f "$REG_DIR/compose/compose.override.yml" "$@"
}

# curl from the host to https://ak.internal through the loopback port, with the
# internal CA and the real hostname (SNI and Host header are ak.internal).
akcurl() {
  curl --resolve "$AK_HOST:${HTTPS_PORT:-30446}:127.0.0.1" --cacert "$CA" "$@"
}
# URL prefix to use with akcurl
AK_HOST_URL() { echo "https://$AK_HOST:${HTTPS_PORT:-30446}"; }

# Admin API token (minted by bootstrap.sh into .tokens/admin.token) so scripts
# do not log in on every run (the login endpoint is rate limited).
admin_token() {
  [[ -s "$TOKENS/admin.token" ]] || { echo "$TOKENS/admin.token missing: run make bootstrap" >&2; return 1; }
  cat "$TOKENS/admin.token"
}
