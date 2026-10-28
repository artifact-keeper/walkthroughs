#!/usr/bin/env bash
# Curation in approved-list mode (idempotent). The names in the reviewed lockfiles
# (app/uv.lock, app/package-lock.json, internal/build-constraints.txt: the build backend of
# the internal package) plus the lab test names are allowed; every other name is refused
# before any package file is downloaded:
#   403 {"error":"curation_blocked","package":...,"reason":"not on the approved list ..."}
# Rules are attached to each remote and virtual of the format (PyPI checks member rules,
# npm checks the virtual's own). Approve one more name later with policies/approve.sh.
# Versions of approved names still go through the age gate and the scan (policies/apply.sh).
# npm names: curation folds `-`, `_` and `.`, so the npm remotes are also limited to the exact
# approved spellings (sync_npm_spellings in lib.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
APP="$here/../app"
PYPI_REPOS=(pypi-remote pypi-lab pypi-virtual pypi-lab-virtual)
NPM_REPOS=(npm-remote npm-lab npm-virtual npm-lab-virtual)
BLOCK_REASON="not on the approved list; ask the platform team to review it"

pypi_names() { # every package in uv.lock except the project itself, the build backend, the lab test names
  awk '/^\[\[package\]\]/{p=1} p && /^name = /{gsub(/"/,"",$3); print $3; p=0}' "$APP/uv.lock" | grep -vx acme-agent
  printf '%s\n' "$build"
  printf '%s\n' lab-agent-sdk
}
npm_names() {
  jq -r '.packages | to_entries[] | select(.key != "") | .key | sub("^.*node_modules/"; "")' "$APP/package-lock.json"
  printf '%s\n' lab-mcp-weather
}

existing=$(body_of "$(api GET '/curation/rules?per_page=1000')" | jq -c '(if type=="array" then . else (.items // .rules // []) end)
  | map({k: ((.staging_repo_id // "global") + " " + .package_pattern + " " + .action)}) | map(.k)')
have() { jq -e --arg k "$1" 'index($k) != null' <<<"$existing" >/dev/null; }
rule() { # repo-id pattern action priority reason
  have "$1 $2 $3" && return 0
  local r; r=$(api POST /curation/rules -d "$(jq -nc --arg id "$1" --arg p "$2" --arg a "$3" --argjson pr "$4" --arg why "$5" \
      '{staging_repo_id:$id,package_pattern:$p,version_constraint:"*",action:$a,priority:$pr,reason:$why,rule_type:"pattern",scope:"repository"}')")
  must "curation rule $2 ($3)" "$r"; added=$((added + 1))
}

build=$(sed -nE 's/^([A-Za-z0-9._-]+)==.*/\1/p' "$here/../internal/build-constraints.txt")
for fmt in pypi npm; do
  if [[ $fmt == pypi ]]; then repos=("${PYPI_REPOS[@]}"); mapfile -t names < <(pypi_names | sort -u); src=app/uv.lock
  else repos=("${NPM_REPOS[@]}"); mapfile -t names < <(npm_names | sort -u); src=app/package-lock.json; fi
  for k in "${repos[@]}"; do
    id=$(repo_id "$k"); added=0
    for n in "${names[@]}"; do
      if [[ $fmt == pypi ]] && grep -qix -- "$n" <<<"$build"; then rule "$id" "$n" allow 100 "approved: reviewed in internal/build-constraints.txt"
      else rule "$id" "$n" allow 100 "approved: reviewed in $src"; fi
    done
    rule "$id" '*' block 1000 "$BLOCK_REASON"
    r=$(api PATCH "/repositories/$k" -d '{"curation_enabled":true,"curation_default_action":"allow"}'); must "curation on $k" "$r"
    echo "policies: curation $k: ${#names[@]} approved names, catch-all block ($added rules added)"
  done
done
sync_npm_spellings
