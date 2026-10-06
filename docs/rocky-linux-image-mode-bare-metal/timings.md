# Timings

All numbers are wall clock, on one host (24 cores, 125 GB RAM), with the same VM shape
(6 vCPU, 8 GiB, 40 GB qcow2, OVMF, virtio, slirp networking) and Artifact Keeper v1.10.2 on
the same host. The KVM numbers are the canonical ones: signed images, `-accel kvm -cpu host`,
installer stage2 served locally. Sources: the [signing log](findings-signing.md#timings-kvm-this-run-vs-tcg-iteration-1-run-3),
the [deploy log](findings-deploy.md#timings) and `deploy/state/timings.log`.

## With KVM

| Stage | Time |
|---|---|
| `vm-install` total | **65 s** |
| power-on to ssh | **25 s** |
| ssh to RKE2 node Ready | **61 s** (86 s from power-on) |
| nginx-demo Running | already Running when checked (< 21 s after Ready) |
| `vm-upgrade-unsigned`: `bootc upgrade` refused | < 1 s |
| `vm-upgrade`: promote (`skopeo copy`) | 1 s |
| `vm-upgrade`: `bootc upgrade` pull + stage (3 layers, 7.8 MB) | **6 s** |
| `vm-upgrade`: reboot to ssh | **20 s** |
| `vm-rollback`: reboot to ssh | 101 s (both times) |
| negative install (`unsigned-test`) until `vm-install` aborts | 40 s (46 s wall) |
| **power-on to working cluster** | **about 3 min** (65 + 25 + 61 + ~20 s) |

The rollback reboot is slower than the upgrade reboot; this was not investigated (no
stop-job timeouts in the serial log).

## KVM vs TCG

TCG is QEMU's software CPU emulation, used when there is no `/dev/kvm`
(`-accel tcg,thread=multi -cpu max`). The TCG column comes from an earlier full run with
unsigned images and the installer stage2 fetched from the mirror; the VM steps are otherwise
the same.

| Stage | KVM | TCG | Notes |
|---|---|---|---|
| `vm-install` total | **65 s** | 601 s | KVM serves stage2 locally |
|  - QEMU start to "Starting installer" | 25 s | 315 s | |
|  - to "Installing the software" | +15 s | +60 s | `%pre` now also fetches the key |
|  - `ostreecontainer` pull + deploy (74 layers, 463 MB) | 15 s | 195 s | |
|  - post-install to QEMU exit | 10 s | 30 s | |
| `vm-install`, stage2 from dl.rockylinux.org | 276 s to "Starting installer" | (315 s) | 750 MB `install.img` at about 3 MB/s = 250 s; the network, not the CPU |
| `vm-boot`: power-on to ssh | **25 s** | 52 s | |
| `vm-boot`: ssh to node Ready | **61 s** | 272 s | |
| `vm-verify`: nginx-demo Running | < 21 s after Ready | 76 s after Ready | |
| `vm-upgrade`: promote copy | 1 s | 1 s | manifest-only |
| `vm-upgrade`: `bootc upgrade` pull + stage | **6 s** | 69 s | 3 layers, 7.8 MB |
| `vm-upgrade`: reboot to ssh | **20 s** | 148 s | includes finalize-staged at shutdown |
| after upgrade: workload re-settled | 81 s | 30-105 s | mostly the RKE2 restart and Deployment rollout |
| `vm-rollback`: reboot to ssh | 101 s | 148 s | |
| after rollback: workload re-settled | 122 s | 30-105 s | |
| **power-on to working cluster** | **about 3 min** | **about 17 min** | |

Under KVM the slowest part of an install was downloading the 750 MB installer stage2 from the
mirror, so `deploy/fetch-media.sh` caches it and `serve-ks.sh` serves it next to the kickstart
(`STAGE2=mirror` restores the old behaviour). Under TCG a clean shutdown takes about 90 s.

## Build side (no VM)

| Step | Time |
|---|---|
| `make registry-up`, cold start to `/readyz` | about 60 s |
| base image (RESF recipe, `minimal`) | 211 s (upstream `standard` recipe unmodified: 4 min 53 s) |
| `rpms/build.sh`: build + sign two RPMs | 7 s |
| edge image, OS layer rebuilt | 27 s |
| edge image, further release (OS layer cached) | 8 s |
| `unsigned-test` image | 1 s |
| push per image (only new layers) | 1-2 s |
| cosign sign per image | 1 s |
| Docker Hub proxy, cold `podman pull nginx:alpine` | 2.2 s |

## Earlier runs

From the lab notes, for comparison only:

- TCG installs of earlier image builds took 555 s (a stand-in k3s image), 600 s and 585 s.
- The first edge image builds took 22-24 s with a cold RKE2 proxy cache (the RKE2 RPMs were
  fetched through Artifact Keeper during the build).
