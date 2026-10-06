# Fedora bootc base images

Create and maintain base *bootable* container images from Fedora packages.

## Motivation

The original Docker container model of using "layers" to model applications has
been extremely successful. This project aims to apply the same technique for
bootable host systems - using standard OCI/Docker containers as a transport and
delivery format for base operating system updates.

## Building images

The current default user experience is to build *layered* images on top of the official
binary base images produced and tested by this project. See the documentation[5] for more info.

If you want total control over the image, you don't need to fork this repository.
Instead, you can use the existing container as a "builder" to make new images.
For more information, see the documentation[6].

## Build process

Building the images in this repo can be done with `podman build`, but
note the build process uses a special podman-ecosystem specific mechanism
to create fully custom images while inside a `Containerfile`.
You need to enable some privileges as nested containerization is required.

```bash
podman build --security-opt=label=disable --cap-add=all \
  --device /dev/fuse -t localhost/fedora-bootc .
```

See the `Containerfile` for more details. This builds the default `standard` image.

## Fedora versions

By default, the base images are built for Fedora rawhide. To build against a
different Fedora version, you can override the `FROM` image used to obtain the
Fedora repos and dnf variables. E.g.:

```bash
podman build --from quay.io/fedora/fedora:41 ...
```

## Content sets/tiers

Documentation above referenced the scratch[6] flow,
but there is also a `minimal-plus` that is not exposed as a stable
interface, but may be used by other images in Fedora.

- **standard**: This image is the default, what is published as
  <https://quay.io/repository/fedora/fedora-bootc>
- **minimal**: This content set is more of a convenient centralization point for CI
  and curation around a package set that is intended as a starting point for
  a container base image.
- **minimal-plus**: This content set is intended to be the shared base used by all image-based
  Fedora variants (IoT, Atomic Desktops, and CoreOS).

**standard** inherits from **minimal-plus** and **minimal-plus** in turn inherit from **minimal**.

All non-trivial changes to **minimal** and **minimal-plus** should be ACKed by at least
one stakeholder of each Fedora variant WGs.

### Available Tiers + Versions

> **NOTE:** The location and naming of these images is subject to change.

| Version | standard | minimal | minimal-plus |
| ------- | -------- | ------- | ------------ |
| Rawhide | quay.io/fedora-testing/fedora-bootc:rawhide-standard | quay.io/fedora-testing/fedora-bootc:rawhide-minimal | quay.io/fedora-testing/fedora-bootc:rawhide-minimal-plus |
| Fedora 42 | quay.io/fedora-testing/fedora-bootc:42-standard | quay.io/fedora-testing/fedora-bootc:42-minimal | quay.io/fedora-testing/fedora-bootc:42-minimal-plus |

## More information

Documentation: <https://docs.fedoraproject.org/en-US/bootc/>

## Badges

| Badge                   | Description          | Service      |
| ----------------------- | -------------------- | ------------ |
| [![Renovate][1]][2]     | Dependencies         | Renovate     |
| [![Pre-commit][3]][4]   | Static quality gates | pre-commit   |

[1]: https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovate
[2]: https://renovatebot.com
[3]: https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit
[4]: https://pre-commit.com/
[5]: https://docs.fedoraproject.org/en-US/bootc/building-containers/
[6]: https://docs.fedoraproject.org/en-US/bootc/building-from-scratch/
