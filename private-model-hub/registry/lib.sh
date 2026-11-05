# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Shared helpers for the ak-hf scripts. Source it; do not run it.
# Defines: REG_DIR, ROOT, ENV_FILE, OUT, CA, TOKENS, AK_HOST, AK_URL, NET, OFFLINE_NET, PROJECT,
# LAB_IP, compose(), akcurl(), AK_HOST_URL(), admin_token(), tok().
REG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$REG_DIR/.." && pwd)"
ENV_FILE="$REG_DIR/.env"
OUT="$REG_DIR/out"
CA="$OUT/ak-internal-ca.crt"
TOKENS="$REG_DIR/.tokens"
AK_HOST=ak.internal
AK_URL="https://$AK_HOST"
NET=ak-hf-net
OFFLINE_NET=ak-hf-offline
PROJECT=ak-hf

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE missing; run registry/up.sh first" >&2; return 1; }
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  HTTPS_PORT="${HTTPS_PORT:-30449}"
  AK_NET_SUBNET="${AK_NET_SUBNET:-172.31.80.0/24}"
  AK_OFFLINE_SUBNET="${AK_OFFLINE_SUBNET:-172.31.81.0/24}"
  # The lab Hub (lab-hub/) sits at .200 of the stack's network.
  LAB_IP="${AK_NET_SUBNET%.*/*}.200"
  export HTTPS_PORT AK_NET_SUBNET AK_OFFLINE_SUBNET LAB_IP
}

compose() {
  podman compose --env-file "$ENV_FILE" -p "$PROJECT" \
    -f "$REG_DIR/compose/docker-compose.yml" \
    -f "$REG_DIR/compose/compose.override.yml" "$@"
}

# curl from the host to https://ak.internal through the loopback port, with the
# internal CA and the real hostname (SNI and Host header are ak.internal).
akcurl() {
  curl --resolve "$AK_HOST:${HTTPS_PORT:-30449}:127.0.0.1" --cacert "$CA" "$@"
}
# URL prefix to use with akcurl
AK_HOST_URL() { echo "https://$AK_HOST:${HTTPS_PORT:-30449}"; }

# Admin API token (minted by bootstrap.sh into .tokens/admin.token) so scripts
# do not log in on every run (the login endpoint is rate limited).
admin_token() {
  [[ -s "$TOKENS/admin.token" ]] || { echo "$TOKENS/admin.token missing: run make bootstrap" >&2; return 1; }
  cat "$TOKENS/admin.token"
}
tok() { cat "$TOKENS/$1.token"; }
