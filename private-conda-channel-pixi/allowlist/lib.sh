# Helpers for the allowlist scripts. Source it.
# REPO: the virtual channel the allowlist is set on (default conda-virtual).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
U=$(AK_HOST_URL)
REPO="${REPO:-conda-virtual}"
log() { echo "allowlist: $*"; }
# api METHOD [curl args...] -> body, then the HTTP code on the last line
api() {
  local m=$1; shift
  akcurl -sS -X "$m" "$U/api/v1/repositories/$REPO/allowlist" -H "Authorization: Bearer $(admin_token)" \
    -H 'Content-Type: application/json' -w '\n%{http_code}' "$@"
}
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
