#!/usr/bin/env bash
# Build localhost/ak-hf/workstation:latest from client/Containerfile with the pins in
# client/VERSIONS. The base image is pulled through oci-dockerhub from the host
# (localhost:30449, developer token). Rootless podman cannot attach a build to a named
# network, so the RUN steps use the host's network and reach Caddy as ak.internal:30449
# (--add-host); they install from pypi-torch and pypi-remote. Prints the versions it holds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
load_env
# shellcheck source=/dev/null
source <(grep -E '^[A-Z0-9_]+=' "$HERE/VERSIONS")
mkdir -p "$HERE/.work"
[[ -s "$CA" ]] || { echo "client/build.sh: $CA missing; run make registry-up first" >&2; exit 1; }
[[ -s "$TOKENS/developer-podman.json" ]] || { echo "client/build.sh: run make bootstrap first" >&2; exit 1; }
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
P="localhost:${HTTPS_PORT}"
podman build --network host --add-host "$AK_HOST:127.0.0.1" --build-arg "AK=https://$AK_HOST:$HTTPS_PORT" --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/developer-podman.json" \
  --secret "id=ak_token,src=$TOKENS/developer.token" \
  --build-arg "REG=$P" --build-arg "PYTHON_IMAGE=$PYTHON_IMAGE" \
  --build-arg "TORCH_VERSION=$TORCH_VERSION" --build-arg "HUGGINGFACE_HUB_VERSION=$HUGGINGFACE_HUB_VERSION" \
  --build-arg "TRANSFORMERS_VERSION=$TRANSFORMERS_VERSION" \
  --build-arg "SENTENCE_TRANSFORMERS_VERSION=$SENTENCE_TRANSFORMERS_VERSION" \
  --label ak-hf=workstation -t localhost/ak-hf/workstation:latest -f "$HERE/Containerfile" "$HERE"
echo "client: versions in localhost/ak-hf/workstation:latest"
podman run --rm localhost/ak-hf/workstation:latest python -c '
import sys, huggingface_hub, transformers, sentence_transformers, torch
print("python                ", sys.version.split()[0])
print("huggingface_hub       ", huggingface_hub.__version__)
print("transformers          ", transformers.__version__)
print("sentence-transformers ", sentence_transformers.__version__)
print("torch                 ", torch.__version__, "(cuda: %s)" % torch.cuda.is_available())' | tee "$HERE/.work/versions.txt"
