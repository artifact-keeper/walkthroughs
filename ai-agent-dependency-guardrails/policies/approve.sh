#!/usr/bin/env bash
# Approve one more package name (after a human review): policies/approve.sh pypi|npm NAME [REASON]
# Adds an allow rule ahead of the catch-all block on every repository of that format.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fmt=${1:?pypi|npm}; name=${2:?package name}; why=${3:-"approved by $(id -un) on $(date -u +%F)"}
case $fmt in pypi) repos=(pypi-remote pypi-lab pypi-virtual pypi-lab-virtual) ;; npm) repos=(npm-remote npm-lab npm-virtual npm-lab-virtual) ;; *) exit 2 ;; esac
for k in "${repos[@]}"; do
  r=$(api POST /curation/rules -d "$(jq -nc --arg id "$(repo_id "$k")" --arg p "$name" --arg why "$why" \
      '{staging_repo_id:$id,package_pattern:$p,version_constraint:"*",action:"allow",priority:100,reason:$why,rule_type:"pattern",scope:"repository"}')")
  must "approve $name on $k" "$r"
done
echo "approved $fmt package $name on ${repos[*]}"
