#!/usr/bin/env bash
# The pi beat of the demo, out/demo/f-pi.cast: on the disconnected site, pi lists
# acme-inventory as connected with its two tools, then answers the stock question with a
# stock_level call. Needs the stack on the site network and make pi run (for pi's home:
# the plugin, mcp.json, models.json). demo/record.sh calls it; it also runs on its own.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
S=.pi/agent/plugins/offgrid-ops/1.0.0/skills/inventory-answers/SKILL.md
[[ -f "out/homes/pi/$S" && -f out/homes/pi/.pi/agent/models.json ]] || { echo "pi-beat.sh: run make pi first" >&2; exit 1; }
mkdir -p out/demo
python3 -I "$HERE/rec.py" out/demo/f-pi.cast --title "pi, an open-source coding agent, on the disconnected site" \
  --idle 1.2 -- bash "$HERE/beat.sh" "pi/run.sh pi mcp list" \
  "pi/run.sh pi --mode json --model offgrid/local --no-builtin-tools --no-skills --append-system-prompt $S \"How many units of SKU OG-1138 are in the north warehouse?\" | jq -rf pi/transcript.jq"
