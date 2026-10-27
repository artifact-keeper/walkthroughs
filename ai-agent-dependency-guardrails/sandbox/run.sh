#!/usr/bin/env bash
# Run a command in the agent sandbox, on agent-net (route to https://ak.internal only),
# with the agent's read-only token. The working directory is mounted at /home/agent/work.
#   sandbox/run.sh [-w DIR] -- CMD...      (DIR defaults to ../app)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
work="$here/../app"
if [[ "${1:-}" == -w ]]; then work="$2"; shift 2; fi
[[ "${1:-}" == -- ]] && shift
token="$(cat "$TOKENS/${SANDBOX_TOKEN:-agent}.token")"
exec podman run --rm -i --network "$AGENT_NET" --userns keep-id \
  -e AK_TOKEN="$token" -e UV_INDEX_AK_PASSWORD="$token" \
  -v "$(cd "$work" && pwd):/home/agent/work:z" \
  localhost/ak-agent/sandbox:1 "$@"
