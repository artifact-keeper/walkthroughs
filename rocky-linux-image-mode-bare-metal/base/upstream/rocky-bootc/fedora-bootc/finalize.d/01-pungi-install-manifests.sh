#!/bin/bash
set -xeuo pipefail

# This is used in the legacy Pungi path. It won't get run in the
# container-native path since install-manifests doesn't copy this script itself
# into usr/share/doc.
target_rootfs=$(pwd)
cd "$RPMOSTREE_WORKDIR"
./install-manifests "$target_rootfs"/usr/share/doc/bootc-base-imagectl/manifests
install -m 0755 -t "$target_rootfs"/usr/libexec bootc-base-imagectl
