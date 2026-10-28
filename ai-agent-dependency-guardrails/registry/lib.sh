# Shared helpers for the ak-agent scripts. Source it; do not run it.
# Defines: REG_DIR, ENV_FILE, OUT, CA, AK_HOST, AK_URL, compose(), akcurl(); load_env() also
# sets AK_NET_SUBNET, AGENT_NET_SUBNET and LAB_IP.
REG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REG_DIR/.env"
OUT="$REG_DIR/out"
CA="$OUT/ak-internal-ca.crt"
TOKENS="$REG_DIR/.tokens"
AK_HOST=ak.internal
AK_URL="https://$AK_HOST"
NET=ak-agent-net
AGENT_NET=agent-net

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE missing; run registry/up.sh first" >&2; return 1; }
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  HTTPS_PORT="${HTTPS_PORT:-30445}"
  # The two networks (/24 each); the lab upstream sits at .200 on the first.
  AK_NET_SUBNET="${AK_NET_SUBNET:-172.31.50.0/24}" AGENT_NET_SUBNET="${AGENT_NET_SUBNET:-172.31.51.0/24}"
  LAB_IP="${AK_NET_SUBNET%.*}.200"
  export AK_NET_SUBNET AGENT_NET_SUBNET LAB_IP
}

compose() {
  podman compose --env-file "$ENV_FILE" -p ak-agent \
    -f "$REG_DIR/compose/docker-compose.yml" \
    -f "$REG_DIR/compose/compose.override.yml" "$@"
}

# curl from the host to https://ak.internal through the loopback port, with the
# internal CA and the real hostname (SNI and Host header are ak.internal).
akcurl() {
  curl --resolve "$AK_HOST:${HTTPS_PORT:-30445}:127.0.0.1" --cacert "$CA" "$@"
}
# URL prefix to use with akcurl
AK_HOST_URL() { echo "https://$AK_HOST:${HTTPS_PORT:-30445}"; }

# Admin API token (minted by bootstrap.sh into .tokens/admin.token) so scripts
# do not log in on every run (the login endpoint is rate limited).
admin_token() {
  [[ -s "$TOKENS/admin.token" ]] || { echo "$TOKENS/admin.token missing: run make bootstrap" >&2; return 1; }
  cat "$TOKENS/admin.token"
}
