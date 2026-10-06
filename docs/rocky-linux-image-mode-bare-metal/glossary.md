# Glossary

Image mode
:   Running the operating system from a container image: the OS is built as a bootc image,
    installed and updated by ostree, and changed by building and publishing a new image
    rather than by running a package manager on each machine.

bootc
:   The tool and the image format for image mode. A *bootc image* is an OCI container image
    that also carries a kernel and boot configuration; `bootc upgrade`, `bootc switch` and
    `bootc rollback` manage which image a machine boots.

ostree
:   The library underneath bootc that stores OS trees content-addressed on disk, keeps several
    deployments side by side, and switches between them at boot. Mentioned here for internals
    only: staging, `ostree-finalize-staged`, the 3-way `/etc` merge.

composefs
:   The read-only root filesystem ostree mounts for the booted deployment. Anything under
    `/usr` (and here `/opt`) is immutable at runtime; `/etc` and `/var` are writable.

Kickstart
:   A text file that answers every question the Rocky installer would ask, so an install runs
    unattended. Here it also writes the signature policy (`%pre`) and installs the image with
    `ostreecontainer`.

Anaconda
:   The installer of Rocky Linux, RHEL and Fedora. It reads the kickstart.

stage2
:   The installer's main image (`install.img`, about 750 MB), fetched by the small boot
    initrd. This PoC caches it and serves it next to the kickstart.

RKE2
:   Rancher's Kubernetes distribution, installed from Rancher's EL10 RPMs. It runs its own
    containerd, which pulls through Artifact Keeper's Docker Hub proxy repository.

canal / CNI
:   CNI (Container Network Interface) plugins set up pod networking. RKE2's default CNI,
    canal (Calico plus Flannel), installs its binaries into `/opt/cni/bin` on the host, which
    is why a read-only `/opt` breaks it.

tmpfiles.d
:   systemd's declarative way to create directories and files at boot. bootc images use it
    for everything under `/var`, since `/var` is not updated with the image.

`policy.json` (containers-policy.json)
:   The file that tells containers-image (podman, skopeo, bootc, ostree-ext, the installer)
    which images to accept, per transport and registry scope: `reject`,
    `insecureAcceptAnything` or `sigstoreSigned` with a key and an identity rule.

Sigstore attachment vs Sigstore bundle
:   Two ways to store a cosign signature in a registry. An *attachment* is a separate tag
    `sha256-<digest>.sig` next to the image; containers-image reads only this format. A
    *bundle* is the newer format cosign 3 writes by default, attached through the referrers
    API; podman, skopeo, bootc and the installer do not read it yet.

Referrers API
:   The OCI registry endpoint `GET /v2/<name>/referrers/<digest>` that lists artifacts
    (signatures, SBOMs) attached to an image digest.

cosign
:   The Sigstore tool that signs and verifies container images. Here it signs each image
    digest with a local key pair, without a transparency log.

NEVRA
:   Name, Epoch, Version, Release, Architecture: the full identity of an RPM, for example
    `edge-site-config-1.0-4.el10.noarch`. Artifact Keeper's hosted repositories treat it as
    immutable (a second upload of the same file name answers 409).

repodata / `repomd.xml`
:   The metadata dnf reads for a repository. `repomd.xml` is the index of the other files;
    `repomd.xml.asc` is its detached signature, checked when `repo_gpgcheck=1`.

Proxy repository vs hosted repository
:   A *proxy repository* (`remote` in Artifact Keeper's API) fetches from an upstream on demand
    and caches what it served. A *hosted* repository (`local` in the API) holds what is
    uploaded to it.

Promotion
:   Making a release live by moving the floating tag to its digest with a registry-side
    `skopeo copy`. The digest does not change, so the existing signature still applies.

Floating tag
:   A tag that is moved from release to release, here `rocky-edge:10`. Nodes track it with
    `bootc upgrade`. The opposite is an immutable tag such as `rocky-edge:10.2-4`, or a digest.
