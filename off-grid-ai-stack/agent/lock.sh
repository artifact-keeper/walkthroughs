#!/usr/bin/env bash
# Write agent/requirements.lock from agent/requirements.in: every pinned version with the
# SHA-256 of each of its files, resolved for CPython 3.12 on Linux x86_64 through Artifact
# Keeper's pypi Virtual (so resolving it also seeds the indexes). Runs while seeding, in the
# agent's base image, with uv installed from pypi-remote. The committed lock is the one of the
# reference run; run this (make lock) to move to newer versions.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
load_env
# shellcheck source=/dev/null
source <(grep -E '^[A-Z0-9_]+=' "$HERE/VERSIONS")
export UV_VERSION
[[ $(phase) == seed ]] || { echo "lock.sh: resolving needs the seed phase (new versions come from upstream)" >&2; exit 1; }
P="localhost:${HTTPS_PORT}"
podman pull -q --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/developer-podman.json" "$P/oci-dockerhub/$PYTHON_IMAGE" >/dev/null
AK_TOKEN=$(tok developer) podman run --rm -i --network "$NET" -e AK_TOKEN -e UV_VERSION \
  -v "$CA:/ca.crt:ro,z" -v "$HERE:/w:z" "$P/oci-dockerhub/$PYTHON_IMAGE" bash -euc '
  cat /ca.crt >> /etc/ssl/certs/ca-certificates.crt
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore
  idx="https://developer:$AK_TOKEN@ak.internal/pypi/pypi/simple/"
  pip install -q --index-url "$idx" "uv==$UV_VERSION"
  UV_INDEX_URL="$idx" uv pip compile -q /w/requirements.in --generate-hashes --python-version 3.12 \
    --python-platform x86_64-manylinux_2_28 --no-header --custom-compile-command "agent/lock.sh" -o /w/requirements.lock.new
  sed -i "s#$AK_TOKEN#<token>#g" /w/requirements.lock.new'
mv "$HERE/requirements.lock.new" "$HERE/requirements.lock"
echo "lock.sh: $(grep -cE '^[a-z0-9]' "$HERE/requirements.lock") packages pinned in agent/requirements.lock"
