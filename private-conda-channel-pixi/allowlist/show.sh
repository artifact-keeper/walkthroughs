#!/usr/bin/env bash
# Print the virtual channel's allowlist: enabled, entry count, one line per entry.
# Usage: allowlist/show.sh   (env REPO, default conda-virtual; JSON=1 for the raw response)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
r=$(api GET)
[[ $(code_of "$r") == 200 ]] || { echo "show.sh: GET $REPO/allowlist: HTTP $(code_of "$r") $(body_of "$r")" >&2; exit 1; }
if [[ "${JSON:-0}" == 1 ]]; then body_of "$r" | jq .; exit 0; fi
body_of "$r" | jq -r --arg repo "$REPO" '
  "\($repo): enabled=\(.enabled) entries=\(.entry_count)",
  (.entries[] | "  \(.name)\t\(.version // "*")\t\((.subdirs // ["*"]) | join(","))")' | column -t -s $'\t'
