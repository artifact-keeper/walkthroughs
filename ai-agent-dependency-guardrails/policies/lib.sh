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
must() {
  [[ $(code_of "$2") =~ ^20 ]] && return 0
  [[ $(code_of "$2") == 401 ]] && { echo "policies: $1 failed: token rejected: run make bootstrap" >&2; exit 1; }
  echo "policies: $1 failed: HTTP $(code_of "$2") $(body_of "$2")" >&2; exit 1
}
must "checking the admin token" "$(api GET /auth/me)"
repo_id() { body_of "$(api GET "/repositories/$1")" | jq -r .id; }
REMOTES=(pypi-remote pypi-lab npm-remote npm-lab)
VIRTUALS=(pypi-virtual npm-virtual pypi-lab-virtual npm-lab-virtual)
NPM_REMOTES=(npm-remote npm-lab)

# Curation compares npm names folded like PyPI names (`-`, `_`, `.` and case), so an allow
# rule for side-channel-list also lets side_channel_list through (F12). The npm remotes
# therefore fetch only the exact spellings that have an allow rule: their upstream filter's
# include list is regenerated from those rules (the exclude list, e.g. @acme/*, is kept).
sync_npm_spellings() {
  local k id names inc r
  for k in "${NPM_REMOTES[@]}"; do
    id=$(repo_id "$k")
    names=$(body_of "$(api GET '/curation/rules?per_page=1000')" | jq -r --arg id "$id" \
      '(if type=="array" then . else (.items // .rules // []) end)[]
       | select(.staging_repo_id == $id and .action == "allow") | .package_pattern' | sort -u)
    if grep -qvE '^(@[a-z0-9][a-z0-9._~-]*/)?[a-zA-Z0-9][a-zA-Z0-9._~-]*$' <<<"$names"; then
      echo "policies: $k has an allow rule that is not a plain npm name; not filtering spellings" >&2; return 1
    fi
    # One regex per ~400 bytes of names: ^/?(name|@scope(/|%2F)name|...)(/|$|?), dots literal.
    inc=$(sed -e 's/[.]/[.]/g' -e 's#^\(@[^/]*\)/#\1(/|%2[Ff])#' <<<"$names" | awk '
      { if (cur != "" && length(cur) + length($0) > 400) { print "^/?(" cur ")(/|$|[?])"; cur = "" }
        cur = (cur == "" ? $0 : cur "|" $0) }
      END { if (cur != "") print "^/?(" cur ")(/|$|[?])" }' | jq -R . | jq -sc .)
    r=$(api GET "/repositories/$k/upstream-filter"); must "reading the $k upstream filter" "$r"
    r=$(api PUT "/repositories/$k/upstream-filter" -d "$(body_of "$r" | jq -c --argjson inc "$inc" \
          '{include_patterns:$inc, exclude_patterns:(.exclude_patterns // [])}')")
    must "upstream filter on $k" "$r"
    echo "policies: $k fetches only the exact spellings of $(wc -l <<<"$names") approved names ($(jq length <<<"$inc") include patterns)"
  done
}
