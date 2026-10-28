#!/usr/bin/env bash
# Approve one more package name (after a human review): policies/approve.sh pypi|npm NAME [REASON]
# Adds an allow rule ahead of the catch-all block on every repository of that format
# (skipped where an allow rule for that name exists already). For npm, the remotes' exact
# spelling list is refreshed too (see sync_npm_spellings in lib.sh).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fmt=${1:?pypi|npm}; name=${2:?package name}; why=${3:-"approved by $(id -un) on $(date -u +%F)"}
case $fmt in pypi) repos=(pypi-remote pypi-lab pypi-virtual pypi-lab-virtual) ;; npm) repos=(npm-remote npm-lab npm-virtual npm-lab-virtual) ;; *) exit 2 ;; esac
rules=$(body_of "$(api GET '/curation/rules?per_page=1000')")
added=0
for k in "${repos[@]}"; do
  id=$(repo_id "$k")
  if jq -e --arg id "$id" --arg p "$name" '(if type=="array" then . else (.items // .rules // []) end)
       | any(.staging_repo_id == $id and .package_pattern == $p and .action == "allow" and .version_constraint == "*")' <<<"$rules" >/dev/null; then
    continue
  fi
  r=$(api POST /curation/rules -d "$(jq -nc --arg id "$id" --arg p "$name" --arg why "$why" \
      '{staging_repo_id:$id,package_pattern:$p,version_constraint:"*",action:"allow",priority:100,reason:$why,rule_type:"pattern",scope:"repository"}')")
  must "approve $name on $k" "$r"; added=$((added + 1))
done
[[ $fmt == npm ]] && sync_npm_spellings >/dev/null
if (( added )); then echo "approved $fmt package $name on ${repos[*]}"
else echo "$fmt package $name is approved already on ${repos[*]}"; fi
