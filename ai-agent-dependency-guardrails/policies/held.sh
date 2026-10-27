#!/usr/bin/env bash
# List the versions the cooldown is holding (age-gate reviews), newest request first.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
body_of "$(api GET '/admin/age-gate/reviews?per_page=200')" | jq -r '.items | sort_by(.last_requested_at) | reverse | .[]
  | [.repository_key, .package_name, .package_version, .status] | @tsv' | column -t
