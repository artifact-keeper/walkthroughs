#!/usr/bin/env bash
# Pull the five official client images (Docker Hub, direct) and record their digests in
# clients/out/images.txt. Override an image with IMG_GO, IMG_CARGO, IMG_NPM, IMG_APT, IMG_APK.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${IMG_GO:=docker.io/library/golang:1.26-alpine}"
: "${IMG_CARGO:=docker.io/library/rust:1-slim-bookworm}"
: "${IMG_NPM:=docker.io/library/node:22-alpine}"
: "${IMG_APT:=docker.io/library/debian:12-slim}"
: "${IMG_APK:=docker.io/library/alpine:3.22}"
mkdir -p "$here/out"; : > "$here/out/images.txt"
for img in "$IMG_GO" "$IMG_CARGO" "$IMG_NPM" "$IMG_APT" "$IMG_APK"; do
  podman image exists "$img" || podman pull -q "$img" >/dev/null
  podman image inspect "$img" --format '{{index .RepoDigests 0}}' | tee -a "$here/out/images.txt"
done
