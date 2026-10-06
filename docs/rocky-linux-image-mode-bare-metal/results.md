# Results

This page collects what the finished pipeline produces: how long each stage takes, and the
verification output from a node built by it. The full breakdown is on the
[Timings](timings.md).

## Timings

All numbers are wall clock on one host (24 cores, 125 GB RAM), with the edge node as a QEMU VM
(6 vCPU, 8 GiB, 40 GB qcow2, OVMF, virtio, slirp networking) and Artifact Keeper v1.10.2 on the
same host. The node numbers are with KVM, signed images, and the installer stage2 served
locally.

### Build side

| Step | Time |
|---|---|
| `make registry-up`, cold start to `/readyz` | about 60 s |
| base image (RESF recipe, `minimal`) | 211 s (upstream `standard` recipe unmodified: 4 min 53 s) |
| `rpms/build.sh`: build and sign two RPMs | 7 s |
| edge image, OS layer rebuilt | 27 s |
| edge image, further release (OS layer cached) | 8 s |
| `unsigned-test` image | 1 s |
| push per image (only new layers) | 1-2 s |
| cosign sign per image | 1 s |
| Docker Hub proxy, cold `podman pull nginx:alpine` | 2.2 s |

### Node side, with KVM

| Stage | Time |
|---|---|
| `vm-install` total | **65 s** |
| power-on to ssh | **25 s** |
| ssh to RKE2 node Ready | **61 s** (86 s from power-on) |
| nginx-demo Running | already Running when checked (< 21 s after Ready) |
| `vm-upgrade-unsigned`: `bootc upgrade` refused | < 1 s |
| `vm-upgrade`: promote (`skopeo copy`) | 1 s |
| `vm-upgrade`: `bootc upgrade` pull and stage (3 layers, 7.8 MB) | **6 s** |
| `vm-upgrade`: reboot to ssh | **20 s** |
| `vm-rollback`: reboot to ssh | 101 s (both times) |
| negative install (`unsigned-test`) until `vm-install` aborts | 40 s (46 s wall) |
| **power-on to working cluster** | **about 3 min** (65 + 25 + 61 + ~20 s) |

Power-on to a working, signed, verified Kubernetes node is about three minutes. Under QEMU's
software emulation (no `/dev/kvm`) the same path takes about 17 minutes. The slowest part of
an install turned out to be downloading the installer's 750 MB stage2 from the mirror, so the
harness caches it with `deploy/fetch-media.sh` and serves it next to the kickstart. The
[timings page](timings.md) has the KVM against software-emulation comparison stage by stage.

## Verification output

`make vm-verify` on a freshly installed node:

```text
=== bootc status ===
spec:    image: 10.0.2.2:30080/oci-bootc/rocky-edge:10   transport: registry
booted:  version: 10.2-3   imageDigest: sha256:d4f3ec69bbd3...
=== getenforce ===
Enforcing
=== kubectl get nodes -o wide ===
NAME           STATUS   ROLES                VERSION          OS-IMAGE                        KERNEL-VERSION
edge-node-01   Ready    control-plane,etcd   v1.36.5+rke2r1   Rocky Linux 10.2 (Red Quartz)   6.12.0-211.61.1.el10_2.x86_64
=== workload image / imageID ===
default/nginx-demo-...  docker.io/library/nginx:alpine  docker.io/library/nginx@sha256:df221db8...
=== Artifact Keeper: oci-dockerhub-proxy ===
98 cached objects; images: library/nginx, rancher/hardened-calico, rancher/hardened-coredns,
  rancher/hardened-etcd, rancher/hardened-kubernetes, rancher/klipper-helm, rancher/rke2-runtime, ...
OK: nginx-demo runs nginx:alpine @ sha256:df221db8..., and that manifest is cached in oci-dockerhub-proxy
```

After the day-2 upgrade in [Step 5](5-upgrade-and-roll-back.md), `bootc status` shows
10.2-4 booted with 10.2-3 as the rollback, and the MOTD reads
`edge-site-config 1.0-4.el10: day-2 update via bootc upgrade (release 4)`. After
`bootc rollback` it is back on 10.2-3, manifests included.

## What it adds up to

- **One source of truth.** Artifact Keeper holds the base operating system packages, the
  Kubernetes packages, the site package, the base image, the edge image releases, their
  signatures, the public keys, and every container image the cluster pulled. Every pull we
  could trace was served by Artifact Keeper. "What is running on node 37?" is `bootc status`
  on the node and a digest lookup in one registry.
- **Cheap day 2.** Promotion is a tag copy, rollback is built in, and a site configuration
  change costs each node 7.8 MB.
- **Verified at the point of use.** Every RPM and image, and all repodata whose publisher signs
  it, is verified by the consumer that uses it: dnf, podman, the installer and `bootc`.
- **Image mode fails differently than package mode.** Neither of the two real bugs (the
  read-only `/opt` and the missing `bubblewrap`) showed up in a build or a lint. Keep a CI
  stage that boots the image and upgrades it.

The [Findings overview](findings.md) has the full lab record behind these
results.

**Next:** [Next steps](next-steps.md).
