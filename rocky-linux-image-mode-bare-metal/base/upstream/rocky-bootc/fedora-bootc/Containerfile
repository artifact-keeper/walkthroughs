# In order to make a base image as part of a Dockerfile, this container build uses
# nested containerization, so you must build with e.g.
# podman build --security-opt=label=disable --cap-add=all --device /dev/fuse <...>

# NOTE: This container build will output a single giant layer. It is strongly recommended
# to run the "rechunker" on the output of this build, see
# https://coreos.github.io/rpm-ostree/experimental-build-chunked-oci/

# Override this repos container to control the base image package versions. For
# example, podman build --from=quay.io/fedora/fedora:41 will get you a system
# that uses Fedora 41 packages. Or inject arbitrary yum repos (COPR, etc) here.
#
# Note we also support --build-arg REPOS_IMAGE=quay.io/fedora/fedora:41 here
# since konflux doesn't yet support --from.
ARG REPOS_IMAGE=quay.io/fedora/fedora:rawhide
ARG BUILDER_IMAGE=quay.io/fedora/fedora:rawhide
FROM $REPOS_IMAGE as repos

# BOOTSTRAPPING: This can be any image that has rpm-ostree, selinux-policy-targeted
#                and python3 (for bootc-base-imagectl).
FROM $BUILDER_IMAGE as builder
RUN dnf -y install rpm-ostree selinux-policy-targeted python3
ARG MANIFEST=fedora-standard
# The input git repository has .repo files committed to git rpm-ostree has historically
# emphasized that.  But here, we are fetching the repos from the container base image.
# So copy the source, and delete the hardcoded ones in git, and use the container base
# image ones.  We can drop the ones commited to git when we hard switch to Containerfile.
COPY . /src
# Avoid umask/permission leakage from the outer environment; ref e.g.
# - https://github.com/coreos/coreos-assembler/pull/4277
# - https://gitlab.com/fedora/bootc/base-images/-/merge_requests/254
# This invocation preserves only the executable bit, and specifically we want to remove:
# - setuid/setgid
# - world writability
# NOTE: This adds world-readability, which is what we intend here as all the content
# is public; there's no secrets in our container build.
RUN chmod -R a=rX,u+w /src
WORKDIR /src
RUN rm -vf /src/*.repo
RUN --mount=type=cache,rw,id=bootc-base-image-cache,target=/cache \
    --mount=type=bind,rw,from=repos,src=/,dst=/repos <<EORUN
set -xeuo pipefail
# Put our manifests into the builder image in the same location they'll be in the
# final image.
./install-manifests
# And embed the rebuild script
install -m 0755 -t /usr/libexec ./bootc-base-imagectl
# Verify that listing works
/usr/libexec/bootc-base-imagectl list >/dev/null
# Run the build script in the same way we expect custom images to do, and also
# "re-inject" the manifests into the target, so secondary container builds can use it.
/usr/libexec/bootc-base-imagectl build-rootfs \
    --cachedir=/cache --reinject --manifest=${MANIFEST} /repos /target-rootfs
EORUN

# This pulls in the rootfs generated in the previous step
FROM scratch
COPY --from=builder /target-rootfs/ /

LABEL containers.bootc 1
# This is an ad-hoc way for us to reference bootc-image-builder in
# a way that in theory client tooling can inspect and find. Today
# it isn't widely used.
LABEL bootc.diskimage-builder quay.io/centos-bootc/bootc-image-builder
# https://pagure.io/fedora-kiwi-descriptions/pull-request/52
ENV container=oci
# Make systemd the default
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
