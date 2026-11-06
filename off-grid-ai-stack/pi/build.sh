#!/usr/bin/env bash
# Build localhost/ak-offgrid/pi:latest (step 6) while seeding: Node through oci-dockerhub, pi
# through npm-remote, on top of the agent image (agent/build.sh, built before this). Same build
# setup as agent/build.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../flows/lib.sh"
mkdir -p "$HERE/.work"
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
podman image exists localhost/ak-offgrid/agent:latest || { echo "pi/build.sh: no agent image (agent/build.sh)" >&2; exit 1; }
node_ref=$(manifest '.image[] | select(.name == "node") | .ref')
pv=$(manifest '.npm[] | select(.name == "@earendil-works/pi-coding-agent") | .version')
podman build --network host --add-host "$AK_HOST:127.0.0.1" --build-arg "AK=https://$AK_HOST:$HTTPS_PORT" \
  --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/developer-podman.json" \
  --secret "id=ak_token,src=$TOKENS/developer.token" \
  --build-arg "REG=$P" --build-arg "NODE_IMAGE=${node_ref}" --build-arg "PI_VERSION=$pv" \
  --label ak-offgrid=pi -t localhost/ak-offgrid/pi:latest -f "$HERE/Containerfile" "$HERE" > "$FOUT/pi-build.log" 2>&1 \
  || { tail -20 "$FOUT/pi-build.log"; exit 1; }
echo "pi $(podman run --rm localhost/ak-offgrid/pi:latest pi --version)"
