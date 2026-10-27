# Shared helpers for the policy scripts. Source it; do not run it.
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
must() { [[ $(code_of "$2") =~ ^20 ]] || { echo "policies: $1 failed: HTTP $(code_of "$2") $(body_of "$2")" >&2; exit 1; }; }
repo_id() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }
REMOTES=(pypi-remote pypi-lab npm-remote npm-lab)
VIRTUALS=(pypi-virtual npm-virtual pypi-lab-virtual npm-lab-virtual)
