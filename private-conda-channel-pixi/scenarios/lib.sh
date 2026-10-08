# Helpers for the scenario scripts. Source it; do not run it.
# Reuses registry/lib.sh (load_env, akcurl, AK_HOST_URL, admin_token, TOKENS, CA, NET).
SCN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCN_DIR/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
WORK="$SCN_DIR/.work"; mkdir -p "$WORK"
# Scenario secrets live in scenarios/.env (never committed; the ak-conda
# registry/.env is only read): SCN_NEXUS_ADMIN_PASSWORD, PROGET_API_KEY
SCN_ENV="$SCN_DIR/.env"
[[ -f "$SCN_ENV" ]] && { set -a; source "$SCN_ENV"; set +a; }
ensure_secret() { # NAME: generate once, then export
  local n=$1
  grep -qs "^$n=" "$SCN_ENV" || { (umask 077; echo "$n=Sc$(openssl rand -hex 12)" >> "$SCN_ENV"); }
  set -a; source "$SCN_ENV"; set +a
}
log() { echo "$(basename "$0" .sh): $*"; }
# Wait until URL answers 200; prints seconds waited.
wait_http() { # URL TIMEOUT_S
  local t0=$SECONDS
  until curl -fsS -o /dev/null "$1" 2>/dev/null; do
    (( SECONDS - t0 > $2 )) && { echo "timeout waiting for $1" >&2; return 1; }; sleep 2; done
  echo $((SECONDS - t0))
}
# The consumer token, as upstream credentials for the product's proxy.
consumer_token() { cat "$TOKENS/consumer.token"; }
