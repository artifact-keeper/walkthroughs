#!/usr/bin/env bash
# (Re)start the egress ledger at http://LEDGER_IP:3128 (.200, alias egress-ledger) on the
# network the stack is on now: ak-offgrid-seed while seeding, ak-offgrid-site after make
# disconnect. On the site network it has no route out either, so an attempt to reach an
# upstream is still written down (result connect_failed) and then fails. The ledger file,
# out/ledger/ledger.jsonl, is kept across restarts. The image is pulled from Docker Hub
# directly: the ledger is lab equipment that watches Artifact Keeper, not something it serves.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
load_env
"$here/down.sh"
mkdir -p "$ROOT/out/ledger"
podman run -d --name "$PROJECT-ledger" --network "$NET" --ip "$LEDGER_IP" --network-alias egress-ledger \
  --label ak-offgrid=ledger \
  -v "$here/server.py:/srv/server.py:ro,z" -v "$ROOT/out/ledger:/out:z" \
  "$(grep -E '^LEDGER_IMAGE=' "$here/VERSIONS" | cut -d= -f2-)" \
  python -I /srv/server.py --listen 0.0.0.0:3128 --ledger /out/ledger.jsonl >/dev/null
for _ in $(seq 30); do
  podman logs "$PROJECT-ledger" 2>&1 | grep -q 'egress ledger on' && break; sleep 1
done
echo "ledger: http://$LEDGER_IP:3128 (alias egress-ledger) on $NET; $(wc -l < "$ROOT/out/ledger/ledger.jsonl") lines in out/ledger/ledger.jsonl"
