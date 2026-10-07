#!/usr/bin/env bash
# Rewrite the build `timestamp` in a .conda package's info/index.json (what a
# publisher, or an attacker, controls). Usage: backdate-conda.sh in.conda out.conda epoch-ms
set -euo pipefail
in=$(realpath "$1"); out=$(realpath -m "$2"); ts=$3
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
cd "$w"; unzip -q "$in"
info=$(ls info-*.tar.zst); mkdir x; tar --zstd -xf "$info" -C x
jq --argjson t "$ts" '.timestamp = $t' x/info/index.json > i.json && mv i.json x/info/index.json
rm "$info"; (cd x && tar --zstd -cf "../$info" --owner=0 --group=0 --numeric-owner $(ls -A))
rm -f "$out"; zip -q -0 -X "$out" metadata.json pkg-*.tar.zst "$info"
