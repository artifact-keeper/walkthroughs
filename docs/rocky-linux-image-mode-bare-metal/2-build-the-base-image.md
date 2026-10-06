# Step 2: Build a Rocky Linux image mode base

This page builds the bootc base image that every edge node runs, with every one of its RPMs
fetched through the Artifact Keeper you set up in [Step 1](1-stand-up-artifact-keeper.md).

**Make target:** `make base`, which runs [`base/build.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/base/build.sh) (about 3.5 to
4 minutes).

## Why build the base yourself

The proof of concept uses Rocky Linux because it is a community-run, open-source Enterprise
Linux, and that is exactly what you want underneath hardware you are going to own for a decade.
For image mode, Rocky gives you the recipe instead of a finished image. The Rocky Enterprise
Software Foundation's [`rocky-bootc`](https://git.resf.org/sig_containers/rocky-bootc)
repository (branch `r10`) wraps the Fedora `bootc-base-images` tooling so you can compose
your own bootc base. There are prebuilt bootc images from the commercial Rocky vendor and from
the community, but for a fleet whose packages all have to come from one place, building from
the recipe is the better fit.

So you build the base yourself, and that is what makes the rest of this work: the base image's
RPMs come through Artifact Keeper too.

## How the recipe works

The recipe is a two-stage Containerfile. A `rockylinux:10` builder installs `rpm-ostree`
(ostree is the content store bootc uses to keep the operating system read-only and versioned),
composes a root filesystem from the recipe's manifests, and exports it as a chunked OCI archive
into a bind-mounted directory. The second stage is `FROM oci-archive:./out.ociarchive`. The
build needs these flags:

```text
--cap-add=all --device /dev/fuse --security-opt=label=disable -v $(pwd):/buildcontext
```

We expected that to be a problem for rootless podman. It was not; the recipe built unmodified
in under five minutes, which matters if you want this running in a CI runner.

## Three changes in a wrapper Containerfile

The proof of concept vendors the upstream recipe untouched and makes three changes, all in a
wrapper Containerfile of its own,
[`base/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/base/Containerfile):

```dockerfile title="base/Containerfile (abridged)" hl_lines="1 4-6 8"
ARG BUILDER_IMAGE=localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10
FROM ${BUILDER_IMAGE} as builder
COPY ak-rocky.repo /tmp/ak-rocky.repo
RUN rm -f /etc/yum.repos.d/*.repo \
 && install -m 0644 /tmp/ak-rocky.repo /etc/yum.repos.d/ak-rocky.repo \
 && dnf -y install rpm-ostree selinux-policy-targeted \
 && dnf clean all
ARG MANIFEST=minimal
COPY . /src
WORKDIR /src
RUN --mount=type=cache,target=/workdir /src/build.sh

FROM oci-archive:./out.ociarchive
# ... upstream's post-processing and labels, unchanged
```

1. **The builder image comes from the Artifact Keeper quay.io proxy** instead of Docker Hub.
2. **The builder's dnf repositories are replaced with the Artifact Keeper Rocky proxies**
   before anything is installed. There is no repository setting in the recipe's manifests;
   `rpm-ostree compose rootfs --source-root=/` just reuses the builder's
   `/etc/yum.repos.d`. Replace those files and every one of the 242 RPMs in the base comes
   through the registry. We checked the build log to be sure: every package resolved from
   `rpm-rocky10-baseos` or `rpm-rocky10-appstream`.
3. **`MANIFEST=minimal` instead of the upstream default `standard`.** The standard manifest
   is 450 packages, including sssd, nfs-utils and cloud agents, and its `autoupdates.yaml`
   links `bootc-fetch-apply-updates.timer` into `default.target.wants` under `/usr`. That
   means the node would fetch updates, apply them, and reboot on its own.
   `systemctl is-enabled` reports it as `disabled` because it is a static link rather than
   an enablement, so this is easy to miss. Upgrades in this design are driven by retagging in
   the registry, not by a timer on the node, so `minimal` is the right choice.

## The result

The result is Rocky Linux 10.2 with kernel 6.12 and bootc 1.16.4: 68 chunked layers, 383 MB
compressed, and a clean `bootc container lint`. It is essentially the same shape as the
community image (242 RPMs and 68 layers against 238 and 65), which gave us some confidence it
was done right. `base/build.sh` pushes it as `oci-bootc/rocky-bootc-base:10` plus an
immutable date tag (`10-YYYYMMDD`), and cosign-signs the digest; signing is covered in
[Step 6](6-sign-and-verify.md).

Two build-system details tripped us up, about the working directory and `--no-cache` (the
final stage deletes its own input archive, so the script always builds with `--no-cache`).
Both are in the [image build notes](findings-image.md).

!!! note "If it fails"
    The build log is on the terminal, and the script is safe to re-run. If a broken local
    image exists, `make base-rebuild` forces a fresh build. A push error
    `Would invalidate signatures` is covered in
    [Troubleshooting](troubleshooting.md#would-invalidate-signatures-on-push).

**Next:** [Step 3: Add Kubernetes and site configuration](3-add-kubernetes-and-site-config.md).
