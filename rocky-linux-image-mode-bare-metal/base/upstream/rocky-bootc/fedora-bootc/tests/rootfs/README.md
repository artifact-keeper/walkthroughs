# rootfs tests

This is a set of scripts that sanity check the target
rootfs in a read-only fashion.

To run the tests:

```
podman build --from localhost/fedora-bootc:latest -t localhost/test-bootc .
podman rmi localhost/test-bootc:latest # Clean up any created images
```
