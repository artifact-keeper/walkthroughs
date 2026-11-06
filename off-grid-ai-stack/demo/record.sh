#!/usr/bin/env bash
# The demo run: the whole walkthrough from an empty registry, at full model size, with the
# five story beats recorded as asciicast files in out/demo/ (demo/rec.py), then the web UI
# screenshots (demo/shoot.sh). The stack is left up, disconnected, for live capture;
# make clean removes it.
#   a  make seed          everything lands in Artifact Keeper, the MCP server by /mcp/seed
#   b  make disconnect    cache-only, jobs paused, the network cut
#   c  make agent         the agent on the site: stock_level, 42, the ref
#   e  gates g02 g06      fails safely: the pickle and the GGUF refused, 409, fast 404s
#   d  gates g07          zero egress: G7a-e and the control
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
D="$ROOT/out/demo"
rec() { local name=$1 title=$2; shift 2; python3 -I "$HERE/rec.py" "$D/$name.cast" --title "$title" --idle 1.2 -- bash "$HERE/beat.sh" "$@"; }
make clean
mkdir -p "$D"
make registry-up bootstrap
rec a-seed "Seed: the whole AI stack lands in Artifact Keeper" "make seed"
make vet
rec b-disconnect "Disconnect: cache-only, jobs paused, the network cut" "make disconnect"
rec c-agent "The agent on the disconnected site" "make agent"
make claude
gates/run-all.sh g01 g03 g04 g05 || true
rec e-fails-safely "Fails safely: what was not seeded or vetted is refused" "gates/run-all.sh g02 g06"
rec d-zero-egress "Zero egress: G7a-e and the negative control" "gates/run-all.sh g07"
"$HERE/shoot.sh"
echo "demo: casts in out/demo/, screenshots in out/demo/screens/; the stack stays up on the site network"
