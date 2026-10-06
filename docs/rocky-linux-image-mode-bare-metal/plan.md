# Plan: Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth

!!! note "Historical design document, kept as written; see [Architecture](architecture.md) for the current state."

Status: design locked 2026-10-05. Implementation tracked in this repo; the write-up lives in
the OpenTeams engineering blog (branch `post/rocky-custom-baremetal-deployments`).

## Goal

Show that one artifact registry can hold **everything** an edge fleet boots from:

| Artifact                               | Artifact Keeper repo             | Repo type        |
|----------------------------------------|----------------------------------|------------------|
| Rocky 10 BaseOS / AppStream / extras   | `rpm-rocky10-*`                  | RPM, remote proxy|
| EPEL 10                                | `rpm-epel10`                     | RPM, remote proxy|
| RKE2 (Kubernetes) RPMs                 | `rpm-rke2-common`, `rpm-rke2-1.36` | RPM, remote proxy|
| Our site-config RPM                    | `rpm-edge-site`                  | RPM, hosted      |
| Rocky bootc **base** image (self-built)| `oci-bootc`                      | OCI, hosted      |
| Rocky edge image (base + RKE2 + site)  | `oci-bootc`                      | OCI, hosted      |
| Upstream container images (quay, hub)  | `oci-quay-proxy`, `oci-dockerhub-proxy` | OCI, remote proxy |

A bare-metal node (here: a QEMU VM) network-boots the stock Rocky installer with a kickstart,
pulls the edge image from Artifact Keeper, reboots into it, and comes up with RKE2 running.
Day-2 is `bootc upgrade` against the same registry.

## Constraints on this workstation (why the harness looks the way it does)

- AMD-V is disabled in BIOS: no `/dev/kvm`. QEMU runs with TCG (`-accel tcg,thread=multi`).
  Installs take ~10 min instead of ~2. Everything in `deploy/` must tolerate that.
- No sudo. Everything runs as rootless podman or inside the VM. `bootc-image-builder` is out;
  the Anaconda kickstart path is in (and is the realistic bare-metal story anyway).
- Artifact Keeper runs on the host at `:30080` (plain HTTP). From a container the host is
  `host.containers.internal`; from the VM it is `10.0.2.2`. Registry is marked insecure via a
  `registries.conf.d` drop-in both in kickstart `%pre` and baked into the image.

## Decisions

1. **Base image**: build the RESF SIG/Containers recipe (`git.resf.org/sig_containers/rocky-bootc`,
   branch `r10`) ourselves with rootless podman, with dnf pointed only at the Artifact Keeper RPM
   proxies, and push it as `oci-bootc/rocky-bootc-base:10`. Rocky publishes no official bootc
   image yet. Fallback if the recipe will not build rootless: `ghcr.io/schmidtw/rocky-bootc:10-minimal`
   pinned by digest, re-pushed into `oci-bootc` so the edge image still builds only from Artifact Keeper.
2. **Kubernetes**: RKE2 from `rpm.rancher.io` (real EL10 RPMs: `rke2-server`, `rke2-selinux`),
   proxied through Artifact Keeper (stable channel is 1.36 as of Oct 2026). Also needs `kernel-modules-extra` on EL10. `registries.yaml`
   mirrors `docker.io` to the Artifact Keeper Docker Hub proxy so workload images flow through the
   registry too. Fallback: k3s binary with `INSTALL_K3S_BIN_DIR=/usr/bin` (proven to work here).
3. **Install method**: kickstart `ostreecontainer --url=... --transport=registry --no-signature-verification`.
   The newer `bootc` kickstart command mislabels `/root/.ssh` and `/etc/resolv.conf` on Rocky 10.2
   (sshd and NetworkManager hit AVC denials). Documented as a finding.
4. **Access**: root password locked, Brandon's `~/.ssh/id_ed25519.pub` injected with kickstart
   `sshkey`, SSH forwarded to host port 2222. No interactive passwords anywhere.
5. **Site config RPM** (`edge-site-config`): RKE2 `config.yaml` + `registries.yaml`, MOTD, a
   oneshot unit that seeds `/var/lib/rancher/rke2/server/manifests` from `/usr/share/edge-site/manifests`
   (a sample nginx Deployment pulled via the Docker Hub proxy). Versioned so a bump demonstrates day-2.
6. **Install media**: Rocky 10.2 pxeboot `vmlinuz`/`initrd.img` + `inst.stage2` from the mirror
   (no ISO extraction). Kickstart served from the host with `python3 -m http.server`.

## Repo layout

```
registry/   Artifact Keeper compose wrapper, up/down, bootstrap.sh (creates repos + token, emits edge.repo)
base/       RESF rocky-bootc recipe build -> oci-bootc/rocky-bootc-base:10
rpms/       edge-site-config spec + build.sh (rpmbuild in a rockylinux:10 container) + upload
image/      Containerfile for oci-bootc/rocky-edge:10 (FROM the AK base, dnf only via AK)
deploy/     ks.cfg template, serve-ks.sh, vm-install.sh, vm-boot.sh, vm-ssh.sh, vm-upgrade.sh
docs/       PLAN.md (this), FINDINGS.md (docs-vs-reality, timings, gotchas for the blog)
Makefile    registry-up -> base -> rpm -> image -> vm-install -> vm-boot -> vm-upgrade
```

## Verification gates

1. `registry/VERIFICATION.md`: dnf through proxy, RPM upload + repodata, OCI push/pull, quay proxy. (done)
2. Base image builds rootless, `bootc container lint` passes, pushed to `oci-bootc`.
3. Edge image builds with **zero** non-Artifact-Keeper URLs in dnf config; lint passes; pushed.
4. VM install from kickstart completes unattended; first boot: `bootc status` shows the AK image ref,
   SELinux enforcing, `kubectl get nodes` Ready, sample workload Running with image pulled via AK proxy.
5. Day-2: bump `edge-site-config`, rebuild+push `rocky-edge:10`, `bootc upgrade && reboot` in VM,
   new MOTD/manifests visible, `bootc rollback` returns to previous.

## Blog outline (high level)

1. Why image mode + a registry as source of truth for edge fleets.
2. Standing up Artifact Keeper (and what the docs get wrong).
3. Building the base when the distro has no official bootc image.
4. Layering RKE2 and site config, all pulled from one registry.
5. Kickstart onto bare metal; `ostreecontainer` vs `bootc` finding.
6. Day-2: upgrade and rollback.
7. Timings, gotchas, what we would do differently.

## Iteration 2 (2026-10-06): sign everything, verify everywhere

Goal: no `--no-signature-verification`, no `gpgcheck=0`, anywhere. Artifact Keeper stores the
signatures and the public keys; every consumer verifies.

| Artifact | Signed by | Signature lives in | Verified by |
|---|---|---|---|
| `edge-site-config` RPM | our GPG key (`rpmsign` in the build container) | the RPM header | dnf `gpgcheck=1` in the image build |
| `rpm-edge-site` repodata | Artifact Keeper managed GPG key (`sign_metadata`) | `repodata/repomd.xml.asc` | dnf `repo_gpgcheck=1` |
| Proxied Rocky / RKE2 RPMs | upstream vendors | RPM headers (pass through the proxy) | dnf `gpgcheck=1` with vendor keys |
| `rocky-bootc-base`, `rocky-edge` images | our cosign key, by digest, after push | `oci-bootc` (`sha256-<digest>.sig` tag / referrers) | podman `policy.json` on the build host; Anaconda via `%pre` policy; `bootc upgrade` via policy baked into the image |
| Public keys (cosign, RPM GPG, Rancher) | n/a | Artifact Keeper hosted raw/generic repo `raw-edge-keys` | fetched by build, kickstart `%pre`, and shipped in the RPM |

Decisions: cosign key pair (not keyless; no OIDC on an edge network). Promotion stays a tag copy,
because cosign signatures bind to the digest. Install by digest is recorded in findings but the
demo keeps the floating tag so the day-2 story is unchanged. TLS via Caddy's internal CA is a
stretch goal; the signature chain is the deliverable.

Gates: (6) unsigned image fails `podman build FROM`, fails kickstart, fails `bootc upgrade`, each
with the signature error captured; (7) signed images pass all three; (8) `rpm -K` and dnf
`gpgcheck=1`/`repo_gpgcheck=1` succeed; (9) full install -> boot -> verify -> upgrade -> rollback
with KVM on the signed images, timings recorded.
