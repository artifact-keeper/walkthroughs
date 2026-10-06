# Findings: image layer (registry additions, base, site RPM, edge image)

!!! note "Lab notes"
    Lab notes from 2026-10-05 and 2026-10-06, kept as recorded. Tags here (`10.2-1`, `10.2-2`) predate signing;
    the current equivalents are `10.2-3`/`10.2-4`. See the [Findings overview](findings.md)
    for the summary.

Run on 2026-10-05/06 on the Fedora 44 workstation described in PLAN.md
(24 cores, rootless podman 5.8.7, skopeo 1.22.3, no sudo, no /dev/kvm),
against Artifact Keeper 1.10.2 on `localhost:30080`. Times are wall clock.

## Summary

| Gate (PLAN.md) | Result |
|---|---|
| 2. Base builds rootless, lint passes, pushed | **Yes, RESF recipe path** (no fallback needed). Built first try, 211 s |
| 3. Edge image, zero non-AK URLs, lint, pushed | **Yes.** `bootc container lint --fatal-warnings` clean, 13 passed / 1 skipped |

Final references (from `skopeo inspect --no-creds`):

| Ref | Digest | Layers | Compressed | Uncompressed (local) |
|---|---|---|---|---|
| `oci-bootc/rocky-bootc-base:10` (= `:10-20261006`) | `sha256:c85c88d42d2595b216e09a9fc2b1e3086b4ca7038745bfd2efc79bb10326298a` | 68 | 383 MB | 792 MB |
| `oci-bootc/rocky-edge:10.2-1` (= `:10`) | `sha256:3e5d6afd46ac6566fac47530b1e949e3a10064ebbd08b87aabebf102f61a4b04` | 76 | 463 MB | 1,029 MB |
| `oci-bootc/rocky-edge:10.2-2` | `sha256:2c81015ad92b6c7b77fa19cbe74e9d62d661f725d7b6f6ac4cab58bf023e2726` | 76 | 463 MB | 1,029 MB |

(These are the v3 images with the `/opt` fix (section 5) and bubblewrap + persistent
journal (section 7). Earlier `10.2-1` digests: `05cd8e2d...` (single install layer),
`96615947...` (split layers), `8126cf65...` (`/opt` fix).)

Day-2 delta (`10.2-1` -> `10.2-2`): **2 new layers, 7.7 MB compressed**.

## 1. Registry additions

`registry/bootstrap.sh` now also creates:

| Key | Type | Upstream |
|---|---|---|
| `rpm-rke2-common` | rpm remote | `https://rpm.rancher.io/rke2/stable/common/centos/10/noarch/` |
| `rpm-rke2-1.36` | rpm remote | `https://rpm.rancher.io/rke2/stable/1.36/centos/10/x86_64/` |
| `oci-dockerhub-proxy` | docker remote | `https://registry-1.docker.io` |

and `out/edge.repo(.in)` gained the two RKE2 sections (8 rpm repos total).
Re-running is idempotent (existing repos are skipped).

- **RKE2 minor: 1.36, not 1.34 as PLAN.md says.** `repodata/repomd.xml` returned 200
  for every minor 1.32 through 1.37 under `rke2/stable/<minor>/centos/10/x86_64/`
  (1.38: 404). The RKE2 `stable` channel (`https://update.rke2.io/v1-release/channels`)
  was `v1.36.5+rke2r1`; 1.37 is `latest`. So the key is `rpm-rke2-1.36` and the
  image carries `rke2-server-1.36.5~rke2r1-0.el10`, `rke2-selinux-0.23-1.el10`.
  Note Rancher's `stable/` RPM path contains minors that are not the stable *channel*.
- A key containing a dot (`rpm-rke2-1.36`) is accepted by the API and works as
  `/rpm/rpm-rke2-1.36/` for dnf.
- **Docker Hub proxy works first time.**
  `podman pull --tls-verify=false localhost:30080/oci-dockerhub-proxy/library/nginx:alpine`
  pulled in 2.2 s (cold), digest `sha256:df221db8...abeac2`, identical to
  `docker.io/library/nginx:alpine`. The short form `oci-dockerhub-proxy/nginx:alpine`
  resolves to the same image (the proxy adds `library/`).
  `oci-dockerhub-proxy/rancher/rke2-runtime:v1.36.5-rke2r1` also resolves (HTTP 200).
- **Token realm follows the Host header.** `Www-Authenticate` says
  `Bearer realm="http://10.0.2.2:30080/v2/token"` when the request is made with
  `Host: 10.0.2.2:30080`, so clients inside the VM get a reachable token endpoint.
  Anonymous `GET /v2/token?service=artifact-keeper&scope=repository:oci-dockerhub-proxy/library/nginx:pull`
  returns a token, and `HEAD`/`GET .../manifests/alpine` with it returns 200 and
  an OCI index, which is the flow containerd uses.

## 2. Base image: the RESF recipe builds rootless

Recipe: `git.resf.org/sig_containers/rocky-bootc` branch `r10` at
`3ce80559d966` (2026-01-16), submodule `gitlab.com/fedora/bootc/base-images` at
`a4d59995f567` (2025-10-13). Vendored without `.git` in `base/upstream/rocky-bootc/`
(see `base/UPSTREAM_COMMIT`), 516 KB.

How the recipe works: a `rockylinux:10` builder installs `rpm-ostree`, runs
`bootc-base-imagectl build-rootfs` (= `rpm-ostree compose rootfs` from the
treefile manifests), then `rpm-ostree experimental compose build-chunked-oci`
writes an OCI archive to `/buildcontext/out.ociarchive` through the `-v $(pwd):/buildcontext`
bind mount; the second stage is `FROM oci-archive:./out.ociarchive`.

**Rootless works with the documented flags, unmodified.** As a control, the
pristine upstream recipe built rootless with exactly the README command
(`podman build --security-opt=label=disable --cap-add=all --device /dev/fuse -v $(pwd):/buildcontext ...`)
in 4 min 53 s (MANIFEST=standard, internet mirrors): 450 RPMs, 1.46 GB, 68 layers, lint clean.
Nothing about rootless podman needed changing. The `Read-only file system`
messages from `systemd-udev.post` / `rpm.posttrans` during compose are normal
rpm-ostree noise, not failures.

What we changed (all in `base/Containerfile` + `base/build.sh`; upstream files untouched):

1. **Builder image from Artifact Keeper**: `FROM localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`
   instead of `docker.io/rockylinux/rockylinux:10`. (`podman build --tls-verify=false`
   applies to FROM pulls.)
2. **dnf only via Artifact Keeper**: the builder's `/etc/yum.repos.d/*.repo` are
   deleted and replaced with `ak-rocky.repo` (the three `rpm-rocky10-*` sections of
   `edge.repo.in`, rendered for `host.containers.internal`) *before* the first
   `dnf install`. There is no repo configuration in the recipe itself: the
   treefile manifests have no `repos:` key and `bootc-base-imagectl` runs
   `rpm-ostree compose rootfs --source-root=/`, which uses the builder's
   `/etc/yum.repos.d`. So replacing the builder's repo files is the whole change.
   The build log shows every package from `rpm-rocky10-baseos` / `rpm-rocky10-appstream`
   and no other URL.
3. **`MANIFEST=minimal`** (upstream default `standard`). `standard` pulls in sssd,
   WALinuxAgent-udev, nfs-utils, NetworkManager-cloud-setup, ... and its
   `autoupdates.yaml` links `bootc-fetch-apply-updates.timer` into
   `/usr/lib/systemd/system/default.target.wants` (automatic fetch + apply + reboot;
   `systemctl is-enabled` reports it as `disabled` because it is a static /usr link,
   which is easy to miss). For a fleet whose upgrades are driven by retagging in the
   registry, surprise reboots are wrong, and minimal is 242 RPMs / 792 MB vs 450 / 1.46 GB.
4. **Build from inside the context directory.** `FROM oci-archive:./out.ociarchive`
   is resolved relative to podman's *current working directory*, not the context
   argument. `build.sh` stages upstream + our Containerfile + repo file into
   `base/.work/ctx` and `cd`s there.
5. **`--no-cache` is required for a re-run.** The final stage `rm`s
   `/buildcontext/out.ociarchive` (upstream does this to avoid leaving a 380 MB file
   in your checkout). On a second `podman build`, the builder stage is a cache hit,
   so nothing regenerates the archive and stage 2 fails on a missing
   `oci-archive:./out.ociarchive`. `build.sh` therefore always passes `--no-cache`,
   and skips the build entirely when `localhost/rocky-bootc-base:10` already exists
   (`REBUILD=1` to force).
6. **Stage ordering still works on podman 5.8.7.** The upstream comment says it
   relies on a buildah that predates containers/buildah#5952 (eager base-image
   resolution). With buildah 1.43 (podman 5.8.7) the second stage's `FROM oci-archive`
   was resolved only after stage 1 finished; no change was needed.

Result: Rocky Linux 10.2 (Red Quartz), kernel `6.12.0-211.61.1.el10_2`,
bootc 1.16.4, rpm-ostree 2026.2 (builder), 242 RPMs, 68 chunked layers,
`bootc container lint`: 13 passed, 1 skipped. Same shape as the community image
`ghcr.io/schmidtw/rocky-bootc:10-minimal` (238 RPMs, 65 layers, 383 MB compressed,
790 MB), so the fallback was not needed.

Timing: 211 s total (`time`, 121 s user / 75 s sys) for builder `dnf install`
(85 packages via the proxy), rpm-ostree compose + dracut, chunked OCI export and import.

Tags: `oci-bootc/rocky-bootc-base:10-20261006` (immutable; build date of the
local image, so a re-push of an old build does not mint a new date) and the
floating `:10` made with `skopeo copy` (registry-side, same digest).
The image keeps Rocky's stock `rocky*.repo` (from `rocky-repos`, mirrorlist URLs);
the edge image removes them.

## 3. Site RPM `edge-site-config`

- Built with `rpmbuild` in `localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`
  (rootless, dnf restricted to the AK Rocky proxies, `rpm-build` + `systemd-rpm-macros`).
  Both releases in **5 s** (`--define "rel N"`).
- Upload: `PUT /rpm/rpm-edge-site/packages/<file>` -> HTTP 201. Re-upload of the same
  file name -> **HTTP 409** and the stored file is kept, even if the local bytes differ
  (rpmbuild output is not reproducible). Treat NEVRAs as immutable and bump the release.
- Repodata is regenerated by the server immediately; `primary.xml.gz` lists
  `edge-site-config 1.0-1.el10` and `1.0-2.el10`, and dnf in a container sees both.
- **registries.yaml / containerd mirror syntax.** Artifact Keeper serves the Docker Hub
  proxy under a path prefix (`/v2/oci-dockerhub-proxy/<repo>/...`). containerd mirrors
  are host-level, so the path needs RKE2's `rewrite`:
  ```yaml
  mirrors:
    docker.io:
      endpoint: ["http://10.0.2.2:30080"]
      rewrite:
        "^(.*)$": "oci-dockerhub-proxy/$1"
  ```
  containerd normalises `nginx:alpine` to `library/nginx`, so the request becomes
  `/v2/oci-dockerhub-proxy/library/nginx/manifests/alpine`, which was verified against
  the API (anonymous token, HEAD + GET 200). Because this mirrors *all* of docker.io,
  RKE2's own system images (`docker.io/rancher/rke2-runtime`, charts' images) also flow
  through Artifact Keeper; containerd falls back to the default endpoint if the mirror
  fails. End-to-end confirmation (pod Running, pull visible in AK) is the VM gate.
- `config.yaml` sets `selinux: true` (required by RKE2 on SELinux-enforcing hosts with
  `rke2-selinux`). The RPM also ships the NetworkManager `unmanaged-devices` drop-in from
  RKE2's known-issues page (canal interfaces), since the image runs NetworkManager.
- `edge-site-manifests.service` copies on *every* boot (manifests live in `/usr`, `/var`
  is not updated by `bootc upgrade`), then `restorecon`s the target, so a day-2 image
  re-seeds the changed manifest.
- `rke2-common` owns `/etc/rancher/rke2` (dir) and ships no `config.yaml`, so there is
  no file conflict. `Requires: rke2-server`.

## 4. Edge image

- `FROM localhost:30080/oci-bootc/rocky-bootc-base:10`. podman needs the registry marked
  insecure for FROM: `--tls-verify=false` on `podman build` works, and so does a
  **user-level** drop-in `~/.config/containers/registries.conf.d/50-artifact-keeper-local.conf`
  (`[[registry]] location="localhost:30080" insecure=true`), no sudo needed;
  `image/setup-host.sh` writes it. Verified: without it `skopeo inspect docker://localhost:30080/...`
  fails with `pinging container registry localhost:30080: Get "https://localhost:30080/v2/"...`;
  with it, it succeeds. The drop-in is read even though `~/.config/containers/registries.conf`
  does not exist.
- Repos: base `rocky*.repo` deleted; build uses `--setopt=reposdir=/tmp/build-repos`
  (`host.containers.internal:30080`); the image ships `/etc/yum.repos.d/edge.repo` with
  the same 8 repos at `10.0.2.2:30080` (the node's view). A `RUN` grep fails the build on
  any `baseurl|mirrorlist|metalink` without `:30080/`; `build.sh` repeats the check from
  outside. Result: 8 baseurls, all `:30080`.
- `kernel-modules-extra` is pinned to the base kernel's `VERSION-RELEASE`
  (`rpm -q kernel`); the proxy offers ~20 kernel builds and an unpinned install
  could pull a newer kernel-core alongside.
- Installed on top of the base: 11 packages, 38 MB download (`install_weak_deps=False`).
- **bootc lint warnings (fixed):** the first build passed lint but with 2 warnings:
  - `nonempty-run-tmp: /run/k3s`: `rke2-common` ships `/var/run/k3s` (and `/var/run` is
    a symlink to `/run`). Removed in the same RUN; RKE2 recreates it.
  - `var-tmpfiles`: `/var/lib/rancher`, `/var/lib/rancher/rke2`, `/var/lib/NetworkManager`
    had no tmpfiles.d entries. Added `/usr/lib/tmpfiles.d/50-edge-image.conf`.
  Now `RUN bootc container lint --fatal-warnings` keeps it clean.
- kargs: `/usr/lib/bootc/kargs.d/10-console.toml` = `console=tty0 console=ttyS0,115200n8`.
- Smoke test as a container (`podman run --rm`), all passed with no `--root` tricks:
  `rpm -q` (rke2-server 1.36.5, rke2-selinux 0.23, edge-site-config 1.0-N, kernel and
  kernel-modules-extra 6.12.0-211.61.1, NetworkManager 1.56.0, openssh-server 9.9p1),
  `bootc 1.16.4`, `/usr/lib/systemd/system/rke2-server.service` present,
  `systemctl is-enabled` = enabled for rke2-server, NetworkManager, sshd, edge-site-manifests.
  `/etc/selinux/config` SELINUX=enforcing. `/etc/resolv.conf` is not in the image
  (checked by mounting the image with `podman unshare podman image mount`).
- **Layering for small day-2 deltas.** First version installed RKE2 and the site RPM in one
  `RUN`: a site-config bump changed a 72 MB layer. Split into two RUNs (OS+RKE2, then
  `ARG SITE_RELEASE` + site RPM). Now `10.2-1` -> `10.2-2` differs in 2 layers totalling
  **7.7 MB** compressed (mostly the rpmdb copy); the cost is +27 MB uncompressed for the
  second rpmdb copy. The base's 68 chunked layers are shared byte-for-byte.
- Timings: edge build 22-24 s (cold RKE2 proxy cache: rancher RPMs fetched through AK
  during the build), 8 s for release 2 (layer 1 cached). Push 1-4 s (only new layers;
  base layers already in `oci-bootc`).
- Floating tag `:10` is a registry-side `skopeo copy` of `:10.2-1` (same digest).
  `make promote REL=2` moves it (deploy/vm-upgrade.sh does the same copy).
  Caveat: `make push` re-points `:10` to `REL` (default 1).

Note for the deploy layer: `rocky-edge:10.2-1` / `:10` were first pushed at digest
`sha256:05cd8e2d...` (single install layer), then `sha256:96615947...` (split layers,
IMAGE_READY), then `sha256:8126cf65...` with the `/opt` fix (IMAGE_READY_V2), then
`sha256:3e5d6afd...` with bubblewrap + persistent journal (IMAGE_READY_V3).

## 5. `/opt` is read-only in the RESF base, which breaks RKE2's CNI (found at the VM gate)

Symptom on the installed node: RKE2 stays `NotReady`; canal's `install-cni` init
container fails with `mkdir /opt/cni: read-only file system`.

Cause, traced through the layers:

- fedora-bootc `minimal/postprocess-conf.yaml` sets the rpm-ostree treefile option
  `opt-usrlocal: "root"` ("We want content lifecycled with the image"). With that,
  `/opt` and `/usr/local` are real directories in the image, i.e. part of the read-only
  composefs root at runtime (the base's `/usr/lib/ostree/prepare-root.conf` has
  `composefs enabled = yes`, `sysroot readonly = true`). The classic ostree layout was
  `/opt -> var/opt`, `/usr/local -> ../var/usrlocal`.
- RESF's `Containerfile` then undoes half of it: `RUN rm -rf /usr/local && ln -s /var/usrlocal /usr/local`.
  `/opt` stays a real directory. The base still ships
  `/usr/lib/tmpfiles.d/rpm-ostree-0-integration-opt-usrlocal.conf` (creates `/var/opt`
  and `/var/usrlocal`, comment: "this dropin implements the old model"), so `/var/opt`
  exists on the node but nothing points at it.
- `podman run` cannot show the problem (the container root is writable), and
  `bootc container lint` has no check for it. It only fails on a real deployment.
- RKE2 (containerd `bin_dir`, canal/calico `install-cni`) writes the host CNI plugins to
  `/opt/cni/bin`. No RKE2 RPM ships files under `/opt` (only `filesystem` owns `/opt`).

Fix (edge image, base left as upstream builds it):
`RUN test -z "$(ls -A /opt)"; rm -rf /opt; ln -s var/opt /opt` plus tmpfiles entries
`d /var/opt/cni` and `d /var/opt/cni/bin` in `/usr/lib/tmpfiles.d/50-edge-image.conf`.
`d /var/opt` is not repeated because the base already declares it (twice: in
`rpm-ostree-autovar.conf` and the opt-usrlocal drop-in). `/usr/local -> /var/usrlocal`
was checked and is correct. `build.sh` now asserts both links, and
`systemd-tmpfiles --create --prefix=/var/opt` in the image yields a writable
`/opt/cni/bin`. Lint is still clean with `--fatal-warnings`.

Alternative for anyone building their own base: drop `opt-usrlocal: "root"` (or set it
to `"var"`), or make the RESF Containerfile treat `/opt` like `/usr/local`. Upstream
Fedora/CentOS bootc choose the "root" model on purpose so that software installed to
`/opt` at build time is versioned with the image; the price is that anything writing to
`/opt` at runtime (CNI installers, vendor agents) breaks.

## 6. RKE2 1.36 ingress: traefik and ingress-nginx

On the node both `rke2-traefik` and `rke2-ingress-nginx` HelmCharts were present.
In RKE2 1.36 the choice is the `ingress-controller` option (`rke2 server --help`:
"Ingress Controllers to deploy, one of none, traefik, ingress-nginx; the first value
will be set as the default ingress class"). `--disable` no longer lists either
ingress chart (valid items: rke2-coredns, rke2-metrics-server,
rke2-snapshot-controller, rke2-snapshot-controller-crd, rke2-snapshot-validation-webhook),
so `disable: rke2-ingress-nginx` is not the way to turn it off in 1.36. Left as is for
the PoC: the demo uses a NodePort, and changing `config.yaml` would need a new
`edge-site-config` NEVRA (uploads are write-once). If wanted, the setting is
`ingress-controller: [traefik]` in the next site-config release.

## 7. Day-2 upgrade silently rolled back: no `bwrap` in the base (found at the VM gate)

Symptom: `bootc upgrade` to `10.2-2` staged fine, but after the reboot the node was
back on `10.2-1` and the staged deployment was gone. Nothing on the console said why,
and the previous boot's journal was gone too (see below). `ostree-boot-complete` on the
next boot reported:

```
ostree-finalize-staged.service failed on previous boot: Finalizing deployment: Finalizing SELinux policy: Failed to execute child process "/usr/bin/bwrap" (No such file or directory)
```

Cause:

- A staged deployment is finalized at shutdown by `ostree-finalize-staged.service`.
  When the new deployment's SELinux policy has to be rebuilt (here because the image
  carries `rke2-selinux` policy modules), libostree runs `semodule` inside a
  bubblewrap sandbox against the new deployment's root. `/usr/lib64/libostree-1.so.1`
  in the base contains the literal path `/usr/bin/bwrap` and the string
  `Finalizing SELinux policy`.
- `bubblewrap` is not installed in the RESF minimal base, and nothing requires it:
  `rpm -q --requires ostree ostree-libs bootc` has no bubblewrap dependency on EL10.
- The fedora-bootc manifests do **not** list it either: neither the pinned submodule
  commit `a4d59995` nor fedora-bootc `main` at `69716e2f` (2026-10-05) mention
  `bubblewrap`/`bwrap` anywhere. (So an earlier assumption that fedora-bootc minimal
  includes it could not be confirmed.) The community image
  `ghcr.io/schmidtw/rocky-bootc:10-minimal` does have `bubblewrap-0.10.0-3.el10`
  installed with no package requiring it, i.e. added explicitly. Our builder stage
  has it only as an rpm-ostree dependency, which is why the compose itself worked.
- A failed finalize is not fatal to the shutdown; the bootloader entry for the new
  deployment is never written, so the machine simply boots the old one. `bootc status`
  after reboot shows no staged deployment, which looks exactly like "the upgrade did
  nothing".
- The initial Anaconda `ostreecontainer` install did not hit this (the node booted
  `10.2-1` fine); it showed up only on the staged day-2 path. Why install differs was
  not investigated.

Fix (edge image, base unchanged): `bubblewrap` added to the layer-1 `dnf install`
(63 KB, from `rpm-rocky10-baseos`); `build.sh` checks `test -x /usr/bin/bwrap`.

Second change from the same incident: **persistent journal.** journald defaults to
`Storage=auto`, which only persists if `/var/log/journal` exists; nothing in the base
creates it (the systemd tmpfiles only `z`/`h`-adjust it if present), so every reboot
wiped the evidence of the failed finalize. Added
`d /var/log/journal 2755 root systemd-journal - -` to
`/usr/lib/tmpfiles.d/50-edge-image.conf`; `systemd-tmpfiles --create` in the image
yields `drwxr-sr-x+ root systemd-journal /var/log/journal`.

Lint still 13 passed / 1 skipped with `--fatal-warnings`; smoke test passes for both releases.
`:10` was re-pointed to the new `10.2-1` (the deploy test had promoted it to `10.2-2`).

## Rocky bootc availability (2026-10-05)

What existed upstream when this was built, and why the base is built here:

- `quay.io/rockylinux/rockylinux` has no `-bootc` tags, and docs.rockylinux.org has no
  image-mode page.
- CIQ sells `rlc-bootc` images (Rocky Linux from CIQ) behind a subscription.
- The community image `ghcr.io/schmidtw/rocky-bootc` is rebuilt daily; it served as the
  comparison and the planned fallback for the base (section 2).
- `k3s-selinux` for el10 exists only as a GitHub testing build (`v1.7.testing.4`);
  Rancher's RPM repository has `rke2-selinux` for EL10 (section 1).

## Gotchas {#docs-vs-reality-gotchas-short-list-for-the-blog}

1. RESF recipe: works rootless as documented; the gotchas are re-runs
   (`--no-cache` because stage 2 deletes its own input) and that the `oci-archive:` path
   is CWD-relative.
2. Pointing the recipe at a private mirror is just replacing the builder's
   `/etc/yum.repos.d`; there is no repo knob in the manifests.
3. Upstream default manifest `standard` silently enables auto-update+reboot via a
   `/usr` wants-symlink (`is-enabled` says `disabled`).
4. Rancher's `rke2/stable/` RPM tree includes minors ahead of the stable channel.
5. RKE2 RPMs ship content in `/var/run` (= `/run`) and `/var/lib`, which bootc lint flags.
6. Artifact Keeper Docker Hub proxy: path-prefixed, so containerd needs `rewrite`;
   `library/` is optional; the token realm follows the Host header.
7. Artifact Keeper RPM upload is write-once per file name (409 on re-upload).
8. The RESF/fedora-bootc base has a read-only `/opt` (`opt-usrlocal: "root"`, and only
   `/usr/local` is re-linked to `/var`). RKE2's CNI install needs `/opt/cni/bin`
   writable; containers and lint can't see the problem, only a booted node.
9. No `bubblewrap` in the base => `bootc upgrade` of an image with extra SELinux modules
   stages, fails to finalize at shutdown, and the node silently boots the old image.
   Nothing requires the package; add it explicitly. Also create `/var/log/journal`, or
   the evidence disappears with the reboot.
10. `storage_used_bytes` for `oci-bootc` reported 4.1 GB after several pushes of images that
   share almost all blobs (~0.9 GB unique); either it counts per-manifest or blobs are not
   deduplicated. Not investigated further.
