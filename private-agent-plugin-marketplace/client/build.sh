#!/usr/bin/env bash
# Build localhost/ak-agents/workstation:latest from client/Containerfile with the pins in
# client/VERSIONS. The ak CLI stage is tagged localhost/ak-agents/ak-cli:<release or rev> so
# that `make clean` (which removes the workstation image) keeps it.
# AK_CLI_RELEASE=source client/build.sh builds ak from source for one run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
_env_release="${AK_CLI_RELEASE-__unset__}"   # an AK_CLI_RELEASE in the environment wins
# shellcheck source=/dev/null
source <(grep -E '^[A-Z_]+=' "$HERE/VERSIONS")
[[ $_env_release != __unset__ ]] && AK_CLI_RELEASE=$_env_release
if [[ -z "$AK_CLI_RELEASE" || "$AK_CLI_RELEASE" == source ]]; then mode=source; AK_CLI_RELEASE=""; else mode=release; fi
mkdir -p "$HERE/.work"
[[ -s "$CA" ]] || { echo "client/build.sh: $CA missing; run make registry-up first" >&2; exit 1; }
cp "$CA" "$HERE/.work/ak-internal-ca.crt"
args=(--build-arg "NODE_IMAGE=$NODE_IMAGE" --build-arg "RUST_IMAGE=$RUST_IMAGE"
      --build-arg "DEBIAN_IMAGE=$DEBIAN_IMAGE" --build-arg "COSIGN_IMAGE=$COSIGN_IMAGE" --build-arg "AK_CLI_MODE=$mode"
      --build-arg "AK_CLI_REV=$AK_CLI_REV" --build-arg "AK_CLI_RELEASE=$AK_CLI_RELEASE"
      --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" --build-arg "CODEX_VERSION=$CODEX_VERSION"
      --build-arg "COPILOT_VERSION=$COPILOT_VERSION")
ak_tag="localhost/ak-agents/ak-cli:${AK_CLI_RELEASE:-$AK_CLI_REV}"
if [[ $mode == release ]]; then echo "client: ak CLI from release $AK_CLI_RELEASE (sha256 and cosign signature checked)"
else echo "client: ak CLI built from source at artifact-keeper-cli@$AK_CLI_REV"; fi
podman build "${args[@]}" --target ak -t "$ak_tag" -f "$HERE/Containerfile" "$HERE"
podman build "${args[@]}" -t localhost/ak-agents/workstation:latest -f "$HERE/Containerfile" "$HERE"
echo "client: versions in localhost/ak-agents/workstation:latest"
podman run --rm localhost/ak-agents/workstation:latest sh -c '
  echo "node        $(node --version)"
  echo "claude      $(claude --version)"
  echo "codex       $(codex --version 2>/dev/null)"
  echo "copilot     $(copilot --version | head -1)"
  echo "cursor      $(cat /opt/cursor/VERSION)"
  echo "ak          $(ak --version)"' | tee "$HERE/.work/versions.txt"
