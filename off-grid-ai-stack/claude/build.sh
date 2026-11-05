#!/usr/bin/env bash
# Build localhost/ak-offgrid/claude:latest (the best-effort step) while seeding: the base image
# through oci-dockerhub, Claude Code through npm-remote. Same build setup as agent/build.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../flows/lib.sh"
mkdir -p "$HERE/.work"
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
node_ref=$(manifest '.image[] | select(.name == "node") | .ref')
cc=$(manifest '.npm[] | select(.name == "@anthropic-ai/claude-code") | .version')
podman build --network host --add-host "$AK_HOST:127.0.0.1" --build-arg "AK=https://$AK_HOST:$HTTPS_PORT" \
  --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/developer-podman.json" \
  --secret "id=ak_token,src=$TOKENS/developer.token" \
  --build-arg "REG=$P" --build-arg "NODE_IMAGE=${node_ref}" --build-arg "CLAUDE_CODE_VERSION=$cc" \
  --label ak-offgrid=claude -t localhost/ak-offgrid/claude:latest -f "$HERE/Containerfile" "$HERE" > "$FOUT/claude-build.log" 2>&1 \
  || { tail -20 "$FOUT/claude-build.log"; exit 1; }
podman run --rm localhost/ak-offgrid/claude:latest claude --version
