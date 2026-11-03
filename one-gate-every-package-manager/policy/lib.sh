# Shared helpers for the policy, exception and gate scripts. Source it; do not run it.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../registry/lib.sh"
load_env
U="$(AK_HOST_URL)"
ADMIN="$(admin_token)"
api() { # api METHOD PATH [curl args...] -> body, then HTTP code on the last line
  local m=$1 p=$2; shift 2
  akcurl -sS -X "$m" "$U/api/v1$p" -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' -w '\n%{http_code}' "$@"
}
code_of() { echo "${1##*$'\n'}"; }
body_of() { echo "${1%$'\n'*}"; }
must() {
  [[ $(code_of "$2") =~ ^20 ]] && return 0
  [[ $(code_of "$2") == 401 ]] && { echo "policy: $1 failed: token rejected: run make bootstrap" >&2; exit 1; }
  echo "policy: $1 failed: HTTP $(code_of "$2") $(body_of "$2")" >&2; exit 1
}
must "checking the admin token" "$(api GET /auth/me)"
repo_id() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }
# The five proxies, in the order the pages use them.
REMOTES=(go-proxy cargo-proxy npm-proxy debian-proxy alpine-proxy)
THRESHOLD="${THRESHOLD:-high}"
# Severity rank, for "at or above the threshold" comparisons.
sev_rank() { case ${1:-} in critical) echo 5;; high) echo 4;; medium) echo 3;; low) echo 2;; info|negligible) echo 1;; *) echo 0;; esac; }
