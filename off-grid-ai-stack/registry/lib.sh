# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Shared helpers for the ak-offgrid scripts. Source it; do not run it.
# Defines: REG_DIR, ROOT, ENV_FILE, OUT, CA, TOKENS, AK_HOST, AK_URL, SEED_NET, SITE_NET, PROJECT,
# LEDGER_IP, BACKEND_IP, PHASE_FILE, phase(), compose(), akcurl(), AK_HOST_URL(), admin_token(), tok().
REG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$REG_DIR/.." && pwd)"
ENV_FILE="$REG_DIR/.env"
OUT="$REG_DIR/out"
CA="$OUT/ak-internal-ca.crt"
TOKENS="$REG_DIR/.tokens"
AK_HOST=ak.internal
AK_URL="https://$AK_HOST"
SEED_NET=ak-offgrid-seed
SITE_NET=ak-offgrid-site
PROJECT=ak-offgrid
# Which network the stack is on: seed (a route out) or site (internal, none). make disconnect
# writes it; compose() adds compose.site.yml while it says site.
PHASE_FILE="$OUT/phase"
phase() { cat "$PHASE_FILE" 2>/dev/null || echo seed; }

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE missing; run registry/up.sh first" >&2; return 1; }
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  HTTPS_PORT="${HTTPS_PORT:-30450}"
  AK_SEED_SUBNET="${AK_SEED_SUBNET:-172.31.84.0/24}"
  AK_SITE_SUBNET="${AK_SITE_SUBNET:-172.31.85.0/24}"
  # Fixed addresses on whichever network the stack is on: the backend at .250 (the plugins
  # Remote's upstream is this instance's own hosted marketplace, see bootstrap.sh) and the
  # egress ledger at .200.
  SEED_PREFIX="${AK_SEED_SUBNET%.*/*}" SITE_PREFIX="${AK_SITE_SUBNET%.*/*}"
  if [[ $(phase) == site ]]; then NET_PREFIX=$SITE_PREFIX NET=$SITE_NET; else NET_PREFIX=$SEED_PREFIX NET=$SEED_NET; fi
  BACKEND_IP="$NET_PREFIX.250" LEDGER_IP="$NET_PREFIX.200"
  export HTTPS_PORT AK_SEED_SUBNET AK_SITE_SUBNET SEED_PREFIX SITE_PREFIX NET_PREFIX NET BACKEND_IP LEDGER_IP
}

compose() {
  podman compose --env-file "$ENV_FILE" -p "$PROJECT" \
    -f "$REG_DIR/compose/docker-compose.yml" \
    -f "$REG_DIR/compose/compose.override.yml" \
    $([[ $(phase) == site ]] && echo -f "$REG_DIR/compose/compose.site.yml") "$@"
}

# curl from the host to https://ak.internal through the loopback port, with the
# internal CA and the real hostname (SNI and Host header are ak.internal).
akcurl() {
  curl --resolve "$AK_HOST:${HTTPS_PORT:-30450}:127.0.0.1" --cacert "$CA" "$@"
}
# URL prefix to use with akcurl
AK_HOST_URL() { echo "https://$AK_HOST:${HTTPS_PORT:-30450}"; }

# Admin API token (minted by bootstrap.sh into .tokens/admin.token) so scripts
# do not log in on every run (the login endpoint is rate limited).
admin_token() {
  [[ -s "$TOKENS/admin.token" ]] || { echo "$TOKENS/admin.token missing: run make bootstrap" >&2; return 1; }
  cat "$TOKENS/admin.token"
}
tok() { cat "$TOKENS/$1.token"; }
