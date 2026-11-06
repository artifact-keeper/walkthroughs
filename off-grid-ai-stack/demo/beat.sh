#!/usr/bin/env bash
# One beat of the demo: print each command after a clean prompt, then run it.
#   beat.sh 'make seed' ['next command' ...]
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for c in "$@"; do
  printf '\033[1;32m~/off-grid-ai-stack$\033[0m %s\n' "$c"; sleep 1
  bash -c "$c"
  echo
done
