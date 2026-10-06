#!/bin/bash
# See the main Containerfile
set -xeuo pipefail
# Some sanity checks
./preflight.sh

# Put our manifests into the builder image in the same location they'll be in the
# final image.
./install-manifests
# And embed the rebuild script
install -m 0755 -t /usr/libexec fedora-bootc/bootc-base-imagectl
# Verify that listing works
/usr/libexec/bootc-base-imagectl list >/dev/null
# Run the build script in the same way we expect custom images to do, and also
# "re-inject" the manifests into the target, so secondary container builds can use it.
/usr/libexec/bootc-base-imagectl build-rootfs --reinject --manifest=${MANIFEST} /target-rootfs
# Now for this we still rely on using a buildah version that predates https://github.com/containers/buildah/issues/5952
rpm-ostree experimental compose build-chunked-oci --bootc --format-version=1 --rootfs /target-rootfs --output oci-archive:/buildcontext/out.ociarchive
