# base/ — Rocky Linux 10 bootc base image, built from the RESF recipe

Rocky publishes no official bootc image. This directory builds one from the
RESF SIG/Containers recipe (`git.resf.org/sig_containers/rocky-bootc`, branch
`r10`) with **rootless podman**, with every RPM fetched through Artifact Keeper,
and pushes it to the hosted OCI repo, then cosign-signs the pushed digest
(`signing/sign-image.sh`; the edge image build refuses an unsigned base):

| Tag | Meaning |
|---|---|
| `localhost:30080/oci-bootc/rocky-bootc-base:10` | floating, what `image/` builds FROM |
| `localhost:30080/oci-bootc/rocky-bootc-base:10-YYYYMMDD` | immutable, build date (UTC) |

## Layout

| Path | What |
|---|---|
| `upstream/rocky-bootc/` | Vendored, unmodified copy of the recipe with its `fedora-bootc` submodule flattened in (no `.git`) |
| `UPSTREAM_COMMIT` | The two upstream commits the vendored copy matches |
| `Containerfile` | Upstream `Containerfile` with the three local changes listed in its header |
| `build.sh` | Stages upstream + our Containerfile + an AK-only repo file (gpgcheck=1, repo_gpgcheck=1, in-image Rocky key) into `.work/ctx`, builds, lints, pushes (`--remove-signatures`), signs |

## Usage

```bash
make base            # or: base/build.sh   (skips the build if localhost/rocky-bootc-base:10 exists)
make base-rebuild    # or: REBUILD=1 base/build.sh
MANIFEST=standard PUSH=0 base/build.sh   # upstream's default manifest, no push
```

Needs: Artifact Keeper up and `registry/bootstrap.sh` run (uses
`registry/out/edge.repo.in` and `registry/.ak-token`), and `make keys` (cosign key).

`podman push --remove-signatures` is needed once the local base has been pulled through
the signature policy (it then carries its sigstore signatures, and pushing from
containers-storage fails with `Would invalidate signatures`). The digest
(`sha256:c85c88d4...`) did not change; the signature lives in `oci-bootc` as the tag
`sha256-c85c88d4...326298a.sig`. `oci-bootc/rocky-bootc-base:unsigned` (same layers,
Docker v2s2 manifest, different digest, no signature) is the negative test.

## What is changed vs upstream

1. Builder stage `FROM localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`
   (was `docker.io/rockylinux/rockylinux:10`).
2. Builder `/etc/yum.repos.d/*` replaced by `ak-rocky.repo` (only
   `rpm-rocky10-{baseos,appstream,extras}` at `host.containers.internal:30080`)
   before the first `dnf install`. `bootc-base-imagectl build-rootfs` runs
   `rpm-ostree compose rootfs --source-root=/`, which takes its repos from the
   builder's `/etc/yum.repos.d`, so the whole rootfs comes through Artifact Keeper.
3. `MANIFEST` defaults to `minimal` (upstream: `standard`). `standard` adds
   sssd, WALinuxAgent-udev, NetworkManager-cloud-setup, nfs-utils, and turns on
   `bootc-fetch-apply-updates.timer` (automatic upgrade + reboot), which is not
   what a fleet driven from a central registry wants. The edge image adds
   NetworkManager and openssh-server itself.

`build.sh` also passes `--no-cache` (see docs/findings-image.md: the final
stage deletes `out.ociarchive`, so a cached builder stage breaks a re-run).

The base keeps Rocky's stock `/etc/yum.repos.d/rocky*.repo` (mirrorlist URLs)
as shipped by `rocky-repos`; `image/` replaces them.

## Verified

Rocky Linux 10.2, kernel `6.12.0-211.61.1.el10_2`, bootc 1.16.4, 242 RPMs, 68 layers,
`bootc container lint` clean. Build log and timings: [image build log](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/findings-image/#2-base-image-the-resf-recipe-builds-rootless).
