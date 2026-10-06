# rocky-bootc

This repository uses the [Fedora bootc base-image](https://gitlab.com/fedora/bootc/base-images)
as a git submodule, and defines the Rocky images.

## More information

- <https://docs.fedoraproject.org/en-US/bootc/>

## Building locally

As this repository uses [git submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules) you must initialize them:

`git submodule update --init --recursive`

After that, you should be able to build with e.g.:

`podman build --security-opt=label=disable --cap-add=all --device /dev/fuse -v $(pwd):/buildcontext -t localhost/rocky-bootc:10 .`

For more on why these capabilities are required, see the upstream docs in <https://gitlab.com/fedora/bootc/base-images>, especially the copy of `Containerfile` there.

Forked from https://gitlab.com/redhat/centos-stream/containers/bootc
