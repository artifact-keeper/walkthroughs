#!/usr/bin/env bash
# Run one package manager's client in a container on the registry network, configured to
# use only https://ak.internal with the stack's internal CA (clients/config/*).
#
#   clients/run.sh TOOL [-w HOSTDIR] [--] CMD...
#     TOOL     go | cargo | npm | apt | apk
#     -w DIR   mount DIR at /work and start there (default: a fresh scratch directory, so
#              every run is cold on the client side and the registry answers every file)
#
# The images are the official client images, pulled by the host's podman straight from
# Docker Hub: this walkthrough is about the package managers inside the containers, not the
# images (the Rocky and conda walkthroughs pull base images through the registry). Nothing
# is installed or executed from the packages the clients fetch.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"; load_env
: "${IMG_GO:=docker.io/library/golang:1.26-alpine}"
: "${IMG_CARGO:=docker.io/library/rust:1-slim-bookworm}"
: "${IMG_NPM:=docker.io/library/node:22-alpine}"
: "${IMG_APT:=docker.io/library/debian:12-slim}"
: "${IMG_APK:=docker.io/library/alpine:3.22}"

tool=${1:?usage: clients/run.sh TOOL [-w DIR] [--] CMD...}; shift
work=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -w) work=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[[ -f "$CA" ]] || { echo "run.sh: $CA missing; run make registry-up" >&2; exit 1; }
if [[ -z $work ]]; then work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; fi
work=$(cd "$work" && pwd)

common=(--rm --network "$NET" -v "$work:/work:z" -w /work -v "$CA:/run/ak/ca.crt:ro,z")
case $tool in
  go)    image=$IMG_GO;    args=(--env-file "$here/config/go.env") ;;
  cargo) image=$IMG_CARGO; args=(-e CARGO_HOME=/tmp/cargo -e HOME=/tmp -v "$here/config/cargo-config.toml:/tmp/cargo/config.toml:ro,z") ;;
  npm)   image=$IMG_NPM;   args=(-e HOME=/tmp -e NPM_CONFIG_USERCONFIG=/run/ak/npmrc -v "$here/config/npmrc:/run/ak/npmrc:ro,z") ;;
  apt)   image=$IMG_APT;   args=(-v "$here/config/apt-sources:/etc/apt/sources.list.d:ro,z" -v "$here/config/apt-conf/99ak:/etc/apt/apt.conf.d/99ak:ro,z") ;;
  apk)   image=$IMG_APK;   args=(-e SSL_CERT_FILE=/run/ak/ca.crt -v "$here/config/apk-repositories:/etc/apk/repositories:ro,z") ;;
  *) echo "run.sh: unknown tool '$tool' (go|cargo|npm|apt|apk)" >&2; exit 2 ;;
esac
exec podman run "${common[@]}" "${args[@]}" ${CLIENT_ARGS:-} "$image" "$@"
