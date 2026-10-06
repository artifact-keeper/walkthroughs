# Findings: deploy layer (kickstart -> bootc node -> RKE2 -> day-2)

!!! note "Lab notes"
    Lab notes from 2026-10-05, kept as recorded. Tags here (`10.2-1`, `10.2-2`) predate signing;
    the current equivalents are `10.2-3`/`10.2-4`. See the [Findings overview](findings.md)
    for the summary.

Workstation: 24 cores, 125 GB RAM, **no /dev/kvm** (AMD-V off in BIOS), so every
VM below runs under QEMU 10.2 TCG (`-accel tcg,thread=multi -cpu max`), 6 vCPU,
8 GiB, 40G qcow2, OVMF, virtio, slirp networking (host = `10.0.2.2`).
Artifact Keeper v1.10.2 on `localhost:30080`. All commands are the `deploy/`
make targets; logs are trimmed, timestamps are local (CDT) unless shown as UTC.

## TL;DR

- **Every gate passes on image v3** (`rocky-edge:10` = `10.2-1` @ `sha256:3e5d6afd...`, and
  `10.2-2` @ `sha256:2c81015a...`), run from a clean disk: unattended kickstart install,
  first boot with SELinux enforcing, RKE2 node Ready, nginx-demo Running from an image
  pulled through Artifact Keeper's Docker Hub proxy, `bootc upgrade` to 10.2-2 (new MOTD,
  new manifests, old digest kept as rollback), `bootc rollback` back to 10.2-1 (old MOTD,
  release-1 manifests re-applied), then a second `bootc rollback` forward to 10.2-2.
- From power-on to a working cluster takes about **17 min under TCG**: 10 min install,
  52 s to ssh, 4.5 min more to node Ready, 1.3 min to workload Running. A day-2
  upgrade takes about 4 min (69 s pull+stage, 148 s reboot).
- Real-install testing caught **two image bugs** that `podman build` and
  `bootc container lint --fatal-warnings` did not (both are now fixed in `image/`):
  1. `/opt` was read-only, so canal could not create `/opt/cni/bin` and the node never went Ready.
  2. `bubblewrap` was missing, so `ostree-finalize-staged` failed at shutdown and
     **`bootc upgrade` silently booted the old image again**.
- The final VM is left running on **10.2-2 (upgraded)**, with 10.2-1 as the rollback:
  `ssh -p 2222 root@localhost`.

## Timings

Run 3, the clean full gate (v3 image, `make vm-clean vm-install vm-boot vm-verify vm-upgrade vm-verify vm-rollback`):

| Stage | Wall time | Detail |
|---|---|---|
| `vm-clean` | 25 s | includes about 20 s for an ACPI poweroff of the previous VM |
| `vm-install` | **601 s** | pxeboot media cached and re-verified (a cold download is about 50 s more for the 214 MB initrd) |
|  - QEMU start to "Starting installer" | 315 s | kernel + initrd + stage2 (`install.img`) fetched over HTTPS from dl.rockylinux.org under TCG |
|  - to "Installing the software" | +60 s | kickstart fetched, storage laid out |
|  - `ostreecontainer` pull + deploy | 195 s | 74 layers, about 463 MB, from `10.0.2.2:30080/oci-bootc/rocky-edge:10` |
|  - post-install to QEMU exit | 30 s | `%post`, bootloader, `reboot` (QEMU `-no-reboot` exits) |
| `vm-boot`: power-on to ssh | **52 s** | (same in runs 1 and 2) |
| `vm-boot`: ssh to node Ready | **272 s** | same in run 2 (324 s from power-on); RKE2 system images pulled through `oci-dockerhub-proxy` |
| `vm-verify`: nginx-demo Running | 76 s after Ready | |
| `vm-upgrade`: promote (`skopeo copy` 10.2-2 -> 10) | 1 s | manifest-only; all blobs already in the repo |
| `vm-upgrade`: `bootc upgrade` pull+stage | **69 s** | "layers needed: 3 (7.8 MB)" (only the site-config layer and its neighbours change) |
| `vm-upgrade`: reboot to ssh | 148 s | includes finalize-staged at shutdown |
| `vm-rollback`: `bootc rollback` + reboot to ssh | 148 s | about 161 s for the whole target |
| after reboot: workload re-settled | 30-105 s | pods restart, manifests re-seeded |

Earlier runs: install 555 s (dev image), 600 s (v1), 585 s (v2).

## Run history (what broke and why)

The harness went through three image revisions. The two failures were both
image-side and both only show up on a real install of a bootc image, never in
`podman build` or `bootc container lint`.

### Run 0: harness shakedown on a stand-in image (`rocky-edge:dev`)

A stand-in k3s bootc image was pushed into Artifact Keeper as
`oci-bootc/rocky-edge:dev` and installed with `make vm-install IMAGE=rocky-edge:dev`:

```
[21:11:39] checking localhost:30080/oci-bootc/rocky-edge:dev
[21:11:39] downloading vmlinuz            ... verified sha256:bdbe11aa...
[21:11:40] downloading initrd.img         ... verified sha256:ba5d8f6e... (214 MB, 47 s)
[21:12:28] accel: -accel tcg,thread=multi -cpu max; 6 vCPU, 8192 MiB
[21:12:28] install: qemu start
[21:16:43] install: Starting installer (+255s)
[21:17:28] install: Starting automated install (+300s)
[21:17:58] install: Installing the software (+330s)
[21:21:13] install: Performing post-installation (+525s)
[21:21:28] install: Installation complete (+540s)
[21:21:43] install: done in 555s
```

### Run 1: `rocky-edge:10` v1 -- RKE2 never Ready: `/opt` is read-only

Install 600 s, ssh up 52 s after power-on, SELinux `Enforcing`, `bootc status`
showing `10.0.2.2:30080/oci-bootc/rocky-edge:10` version `10.2-1`, `rke2-server`
active. But the node stayed `NotReady` for the full 20 min:

```
NAMESPACE     NAME                          READY   STATUS                      AGE
default       nginx-demo-5b786799fb-lxktm   0/1     Pending                     7m59s
kube-system   rke2-canal-9fr5x              0/2     Init:CreateContainerError   7m16s
kube-system   rke2-coredns-...              0/1     Pending                     7m21s

Warning  Failed  kubelet  spec.initContainers{install-cni}: Error: failed to generate
  container "5ab13342..." spec: failed to generate spec: failed to mkdir "/opt/cni/bin":
  mkdir /opt/cni: read-only file system
```

Not a TCG problem: canal's `install-cni` init container hostPath-mounts
`/opt/cni/bin`, and on this bootc image `/opt` is a real directory on the
read-only composefs root (not the classic ostree `/opt -> var/opt` symlink).
The calico image itself had pulled fine through the mirror (55 s). Fixed in the
image (`/opt -> var/opt` plus tmpfiles.d for `/var/opt/cni/bin`).

### Run 2: v2 -- node Ready, workload via proxy, but `bootc upgrade` silently reverts

Install 585 s, ssh 52 s, node Ready 272 s after ssh, nginx-demo Running 39 s
later, image verified in `oci-dockerhub-proxy`. Then `make vm-upgrade`:

```
[22:12:32] upgrade: promote copy took 1s
=== bootc upgrade ===
layers already present: 73; layers needed: 3 (7.7 MB)
Deploying...done (22 seconds)
Queued for next boot: 10.0.2.2:30080/oci-bootc/rocky-edge:10
  Version: 10.2-2
  Digest: sha256:184d5f9f...
[22:16:12] upgrade: reboot to ssh took 148s
  booted:   version: 10.2-1   imageDigest: sha256:8126cf65...      <- still the old one
  rollback: null
[22:16:16] ERROR: booted digest sha256:8126cf65... != staged sha256:184d5f9f...
```

The staged deployment is only written into `/boot` by
`ostree-finalize-staged.service` during shutdown. The serial log shows it
"Stopped" normally, so nothing looked wrong at reboot time. The reason only
appears on the *next* boot, from `ostree-boot-complete.service`:

```
ostree[751]: error: ostree-finalize-staged.service failed on previous boot: Finalizing
  deployment: Finalizing SELinux policy: Failed to execute child process "/usr/bin/bwrap"
  (No such file or directory)
$ rpm -q bubblewrap
package bubblewrap is not installed
```

ostree rebuilds the SELinux policy for the new deployment with `semodule` inside
bubblewrap. That runs here because `rke2-selinux` adds policy modules. The RESF
minimal base does not ship `bubblewrap` (the fedora-bootc minimal manifests do not list
it either; the community `rocky-bootc` image added it explicitly, see the image log
section 7). The journal is volatile on this image, so `journalctl -b -1` had nothing: the diagnosis came from
the serial log plus `systemctl status ostree-boot-complete`.

**Root-cause proof on the same VM, no image change:** `bootc usr-overlay`
(transient writable /usr), `dnf install bubblewrap` (from the Artifact Keeper
repos baked into the image), `bootc upgrade`, reboot:

```
$ rpm -q bubblewrap
bubblewrap-0.10.0-3.el10.x86_64
[22:23:03] guest back after 148s
ostree-boot-complete.service was skipped because no trigger condition checks were met.  <- no failure stamp
  booted:   version 10.2-1  imageDigest: sha256:3e5d6afd...   (the newly staged build)
  rollback: version 10.2-1  imageDigest: sha256:8126cf65...   (previous)
```

With `bwrap` present, finalization succeeds. The image now installs
`bubblewrap` and makes `/var/log/journal` persistent. `vm-upgrade.sh` now prints
the `ostree-boot-complete` journal whenever the booted digest is not the staged one.

### Run 3: v3 -- the full gate from a clean disk

Clean disk (`make vm-clean`), then the full chain against `IMAGE_READY_V3`
(`sha256:3e5d6afd...`). Every stage passed. One harness bug showed up and was
fixed (see the end of this section).

**Install** (milestones from the serial log, followed live by `vm-install.sh`):

```
[22:23:48] checking localhost:30080/oci-bootc/rocky-edge:10
[22:23:48] vmlinuz cached and verified
[22:23:48] initrd.img cached and verified
[22:23:49] serving .../deploy/state/www on 0.0.0.0:8000
[22:23:49] accel: -accel tcg,thread=multi -cpu max; 6 vCPU, 8192 MiB
[22:29:04] install: Starting installer (+315s)
[22:29:49] install: Starting automated install (+360s)
[22:30:04] install: Installing the software (+375s)
[22:33:19] install: Performing post-installation (+570s)
[22:33:34] install: Installation complete (+585s)
[22:33:49] install: done in 600s
```

Serial-console excerpt (Anaconda text mode):

```
Starting installer, one moment...
Not asking for remote desktop session because of an automated install
Starting automated install..Checking storage configuration...
Configuring storage
Installing the software
Installing boot loader
Performing post-installation setup tasks
Configuring installed system
Storing configuration files and kickstarts
Installation complete
```

**First boot:**

```
Booting `Rocky Linux 10.2 (Red Quartz) (ostree:0)'
Command line: BOOT_IMAGE=(hd0,gpt2)/ostree/default-db2852.../vmlinuz-6.12.0-211.61.1.el10_2.x86_64
  ostree=/ostree/boot.0/default/db2852.../0 console=tty0 console=ttyS0,115200n8 ...
[22:34:41] ssh up after 52s
[22:34:42] kubernetes distribution in guest: rke2
=== bootc status ===   (trimmed)
spec:   image: 10.0.2.2:30080/oci-bootc/rocky-edge:10   transport: registry
booted: version: 10.2-1   imageDigest: sha256:3e5d6afd46ac...   store: ostreeContainer
rollback: null
=== getenforce ===
Enforcing
=== insecure registry drop-ins ===
/etc/containers/registries.conf.d/50-artifact-keeper.conf: location = "10.0.2.2:30080"  insecure = true
/etc/containers/registries.conf.d/50-poc-insecure.conf:    location = "10.0.2.2:30080"  insecure = true
[22:39:13] boot: node Ready (+324s since QEMU start, i.e. 272 s after ssh)

NAME           STATUS   ROLES                AGE   VERSION          INTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                          CONTAINER-RUNTIME
edge-node-01   Ready    control-plane,etcd   ...   v1.36.5+rke2r1   10.0.2.15     Rocky Linux 10.2 (Red Quartz)   6.12.0-211.61.1.el10_2.x86_64 (amd64)   containerd://2.3.4-k3s1
```

**Workload through Artifact Keeper** (`make vm-verify`):

```
=== deployments matching nginx (labels show the site-config release) ===
default  nginx-demo  1/1  1  1  app=nginx-demo,edge-site/config-release=1
=== workload image / imageID ===
default/nginx-demo-...  docker.io/library/nginx:alpine  docker.io/library/nginx@sha256:df221db836e1754089190208cee7eeda94f233197056426eda74a43ab1abeac2
=== containerd mirror config (hosts.toml) ===     (generated by RKE2 from registries.yaml)
server = "https://registry-1.docker.io/v2"
[host."http://10.0.2.2:30080/v2"]
  capabilities = ["pull", "resolve"]
  [host."http://10.0.2.2:30080/v2".rewrite]
    "^(.*)$" = "oci-dockerhub-proxy/$1"
=== containerd log: nginx pull ===
time="2026-10-06T03:10:41Z" msg="PullImage \"docker.io/library/nginx:alpine\""
time="2026-10-06T03:11:30Z" msg="Pulled image \"docker.io/library/nginx:alpine\" ... repo digest
  \"docker.io/library/nginx@sha256:df221db8...\", size \"26335715\" in 49.202132411s"
=== Artifact Keeper: oci-dockerhub-proxy ===
98 cached objects; images: library/nginx, rancher/hardened-calico, rancher/hardened-cluster-autoscaler,
  rancher/hardened-coredns, rancher/hardened-etcd, rancher/hardened-flannel, rancher/hardened-k8s-metrics-server,
  rancher/hardened-kubernetes, rancher/hardened-snapshot-controller, rancher/klipper-helm,
  rancher/mirrored-pause, rancher/rke2-cloud-provider, rancher/rke2-runtime
v2/library/nginx/manifests/alpine                                                   10333  4  2026-10-06T03:10:43Z
v2/library/nginx/manifests/sha256:df221db836e1754089190208cee7eeda94f233197056426eda74a43ab1abeac2  0  1  2026-10-06T03:10:44Z
OK: default/nginx-demo-... runs docker.io/library/nginx:alpine @ sha256:df221db8..., and that manifest is cached in oci-dockerhub-proxy
```

The containerd lines and AK timestamps above are from run 2, when the first pull
went through the proxy (the proxy entries were created 2 s after the
`PullImage`). Run 3 hit the same cached manifest (`download_count` went 1 -> 2).

**Day-2 upgrade** (`make vm-upgrade`, defaults `PROMOTE_FROM=rocky-edge:10.2-2`):

```
[22:40:45] booted: 10.0.2.2:30080/oci-bootc/rocky-edge:10@sha256:3e5d6afd...
[22:40:46] promote: localhost:30080/oci-bootc/rocky-edge:10.2-2 -> localhost:30080/oci-bootc/rocky-edge:10
[22:40:47] upgrade: promote copy took 1s
[22:40:47] tag now: sha256:2c81015ad92b...
=== bootc upgrade ===
layers already present: 73; layers needed: 3 (7.8 MB)
Deploying...done (21 seconds)
Queued for next boot: 10.0.2.2:30080/oci-bootc/rocky-edge:10
  Version: 10.2-2
  Digest: sha256:2c81015ad92b6c7b77fa19cbe74e9d62d661f725d7b6f6ac4cab58bf023e2726
[22:41:56] upgrade: bootc upgrade (pull+stage) took 69s
[22:44:25] upgrade: reboot to ssh took 148s
=== bootc status ===   (trimmed)
booted:   version: 10.2-2  imageDigest: sha256:2c81015ad92b...
rollback: version: 10.2-1  imageDigest: sha256:3e5d6afd46ac...
=== /etc/motd.d/edge ===
  Rocky Linux edge node (image mode, RKE2)
  edge-site-config 1.0-2.el10: day-2 update via bootc upgrade (release 2)
  Source of truth: Artifact Keeper at 10.0.2.2:30080
=== edge-site-config ===
edge-site-config-1.0-2.el10.noarch
[22:44:29] upgrade: OK booted=sha256:2c81015a... rollback=sha256:3e5d6afd...
```

(Before the upgrade the MOTD said `edge-site-config 1.0-1.el10: initial site configuration`.)
After the upgrade, RKE2 re-applied the re-seeded manifests and rolled the Deployment:
`nginx-demo ... edge-site/config-release=2`, new pod Running on the same
proxied digest.

**Rollback** (`make vm-rollback`):

```
[22:46:42] booted sha256:2c81015a...; rolling back to sha256:3e5d6afd...
[22:49:19] rollback: reboot to ssh took 148s
booted:   version: 10.2-1  imageDigest: sha256:3e5d6afd...
rollback: version: 10.2-2  imageDigest: sha256:2c81015a...
=== /etc/motd.d/edge ===
  edge-site-config 1.0-1.el10: initial site configuration
[22:49:21] rollback: OK
[22:51:19] verify: OK   nginx-demo ... edge-site/config-release=1
```

The rollback brings back the manifests as well, because
`edge-site-manifests.service` re-seeds `/var/lib/rancher/rke2/server/manifests`
from the booted image's `/usr/share/edge-site/manifests` on every boot. A second
`make vm-rollback` swapped forward again to 10.2-2 (148 s), and
`config-release=2` was back about 2 min after ssh.

**Harness bug found and fixed in this run.** The first `vm-verify` after the
upgrade caught the Deployment mid-rollout: the old pod was Running and the new
one was in ContainerCreating with an empty `imageID`, so it reported
`FAIL: ... digest  not found`. `vm-verify.sh` now waits until `rke2-server` is
active and every matching pod is Running with READY n/n before it checks digests.

## Install method: ostreecontainer vs the bootc kickstart command

The Rocky 10.2 installer ships anaconda 40.22.3.46 and pykickstart 3.52.12. Both install
commands validate there, and both install the edge image, but they do it differently:

- `ostreecontainer --url=... --transport=registry` runs `ostree container image deploy`
  (the exact command line is quoted in the signing log, gate 6:
  `ostree container image deploy --sysroot=/mnt/sysimage --image=10.0.2.2:30080/oci-bootc/rocky-edge:unsigned-test --transport=registry`).
- The newer `bootc` command runs `bootc install to-filesystem` against the installer's
  mounted target. From Anaconda's rhel-10 source:

    ```python
    bootc_cmd = "bootc"
    bootc_args = [
        "install",
        "to-filesystem",
    ]
    ...
    if not arch.is_s390():
        bootc_args.append("--bootloader=grub")
    ```

Two installs of the same image, with kickstarts that differed only in the install command,
gave different SELinux labels on the installed system:

| | `bootc` | `ostreecontainer` |
|---|---|---|
| `/var/roothome/.ssh/authorized_keys` (root's key from `sshkey`) | `var_t` | labelled correctly |
| `/etc/resolv.conf` | `etc_t` | labelled correctly |
| first boot | AVC denials blocked sshd and NetworkManager | sshd and NetworkManager fine |
| `%post` `restorecon -RF` | did not fix it | not needed |

So the kickstart uses `ostreecontainer`. The serial logs of those two installs were not kept
with the repository; the labels and outcomes above are as recorded at the time.

## Other observations

- **Digest race when the tag moves mid-install.** `vm-install.sh` logs the tag's
  digest (via `skopeo inspect`) before Anaconda starts, but Anaconda resolves the
  tag about 5 minutes later. In run 1 a concurrent re-push of `:10` landed in between,
  so the logged digest (`05cd8e2d...`) is not the installed one (`96615947...`).
  Treat `bootc status` as authoritative. A real fleet should install by digest
  (`--url=...@sha256:...`) and track the tag afterwards.
- **Artifact Keeper records some by-digest manifests as size 0** in the
  artifacts API (e.g. `v2/library/nginx/manifests/sha256:df221db8...  0 bytes`,
  the per-platform manifest that containerd resolved from the `alpine` index).
  Pulls work; it is only the listing.
- **containerd does not log which mirror served a pull.** The proof that
  `nginx:alpine` came through Artifact Keeper is that the exact digest in the pod's
  `imageID` exists in `oci-dockerhub-proxy`, created at the same second as the
  `PullImage` line in containerd.log. Every RKE2 system image
  (`rancher/rke2-runtime`, `hardened-kubernetes`, `hardened-etcd`, calico,
  flannel, coredns, klipper-helm, ...) also came through the proxy, because
  `registries.yaml` mirrors all of `docker.io`. Note that RKE2's generated
  `hosts.toml` keeps `https://registry-1.docker.io` as the fallback `server`, so
  an air-gapped site should also block egress.
- **`helm-install-rke2-traefik` errors once or twice** ("Required CRDs are
  missing") before `rke2-traefik-crd` finishes, then succeeds on retry. This is
  the normal RKE2 ordering race, made more visible by TCG.
- **Duplicate kernel args.** `console=ttyS0,115200n8` appears twice on the
  installed cmdline: once from Anaconda (it copies the installer's `console=`)
  and once from the image's `kargs.d`. Harmless.
- **Two insecure-registry drop-ins.** The image ships
  `50-artifact-keeper.conf` and the kickstart `%post` writes
  `50-poc-insecure.conf` with the same `[[registry]]` entry. containers-image
  accepts the duplicate. The `%post` copy is a belt-and-braces for images that
  forget it.
- **SSH under slirp.** Every host connection arrives from `10.0.2.2`, so
  OpenSSH `PerSourcePenalties` would punish the host as a whole. The wait loop
  (`BatchMode=yes`, one key, 10-15 s between tries) never tripped it in about 12
  boots.
- **Clean shutdown under TCG takes about 90 s** (`vm-stop`: RKE2 and containerd
  teardown), and a reboot to ssh takes about 150 s.
