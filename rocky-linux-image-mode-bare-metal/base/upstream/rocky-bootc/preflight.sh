#!/bin/bash
# Run this with a context from the source directory as a sanity
# check. Currently this just verifies that the git submodules are set up.
set -eu
cd $(dirname $0)
if test '!' -f fedora-bootc/fedora-bootc.yaml; then
  echo "Please run:"
  echo " git submodule update --init --recursive"
  exit 1
fi
echo "git submodules check OK"
