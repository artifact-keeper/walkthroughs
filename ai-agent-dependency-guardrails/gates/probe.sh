#!/usr/bin/env bash
# Ask the registry directly, from inside the sandbox with the agent's token, and print its
# answer (status line and body). uv and npm only say "403" or "451"; this shows why.
#   gates/probe.sh pypi/pypi-virtual/simple/huggingface-cli/
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
"$here/../sandbox/run.sh" -w "$scratch" -- python3 - "$1" <<'PY'
import os, sys, urllib.request
url = "https://ak.internal/" + sys.argv[1]
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["AK_TOKEN"]})
try:
    r = urllib.request.urlopen(req, timeout=60)
    print(r.status, r.reason)
except urllib.error.HTTPError as e:
    print(e.code, e.reason)
    print(e.read(600).decode(errors="replace"))
PY
