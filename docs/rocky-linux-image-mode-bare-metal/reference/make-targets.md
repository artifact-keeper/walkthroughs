# Make-target reference

!!! info "Looking for the narrated version?"
    The [step-by-step walkthrough](../index.md) explains each stage with the reasoning and
    screenshots. This page is the reference for every `make` target.

The whole pipeline is driven by `make` from the `rocky-linux-image-mode-bare-metal/` directory. Every target wraps a script
of the same purpose and is safe to re-run; `make help` lists them. Check the host first with
[Environment setup](../environment.md) and `make preflight`.

## The pipeline in seven steps

1. **Registry.** Artifact Keeper v1.10.2 runs under rootless podman compose. An idempotent
   bootstrap creates the repositories, turns on repodata signing for `rpm-edge-site`, and
   mints a CI token.
2. **Keys.** A cosign key pair and an RPM GPG key are generated locally; the public halves
   and the vendor keys are published to `raw-edge-keys`.
3. **Base image.** The RESF SIG/Containers `rocky-bootc` recipe is built rootless with dnf
   pointed only at the Artifact Keeper proxy repositories, pushed to
   `oci-bootc/rocky-bootc-base:10` and cosign-signed (Rocky publishes no official bootc image).
4. **Site RPM.** `edge-site-config` (RKE2 config, registry mirror, MOTD, a demo manifest) is
   built and `rpmsign`ed in a Rocky container and uploaded to `rpm-edge-site`.
5. **Edge image.** `oci-bootc/rocky-edge:10.2-<rel>` layers RKE2 and the site RPM on the
   base, ships the node's signature policy, and fails its own build on any repository URL
   that is not Artifact Keeper or any `gpgcheck=0`.
6. **Install.** The edge node (a QEMU VM in this PoC) netboots the stock Rocky 10.2
   installer (Anaconda); the kickstart writes a signature policy in `%pre` and installs the
   edge image with `ostreecontainer`.
7. **Day 2.** Move the floating tag `:10` to the next release in the registry,
   `bootc upgrade`, reboot; `bootc rollback` returns to the previous image. Unsigned images
   are refused at every step.

Image tags read `rocky-edge:<Rocky minor>-<site-config release>`; `10.2-4` = Rocky 10.2 +
`edge-site-config-1.0-4`.

## Running it

```bash
git clone https://github.com/artifact-keeper/walkthroughs
cd walkthroughs/rocky-linux-image-mode-bare-metal
make preflight
make all            # registry-up keys publish-keys base rpm image push unsigned-test sign verify
make vm-all         # vm-install vm-boot vm-verify vm-upgrade-unsigned vm-upgrade vm-verify vm-rollback vm-verify
```

`make` builds each goal at most once per invocation, so a command line such as
`make vm-upgrade vm-verify vm-rollback vm-verify` runs `vm-verify` only once. `make vm-all`
runs the eight VM scripts in order as plain recipe lines and stops at the first failure.
The step-by-step form is one `make` call per target:

```bash
for t in vm-install vm-boot vm-verify vm-upgrade-unsigned vm-upgrade vm-verify vm-rollback vm-verify; do
  make "$t" || break
done
```

`vm-install` refuses to start while a VM is running; `make vm-clean vm-all` starts from a
fresh disk.

## At a glance

Times are with KVM; under TCG see [Timings](../timings.md).

| Step | First run | Re-run | State written to |
|---|---|---|---|
| `registry-up` | about 60 s to `/readyz` (plus image pulls) | seconds; existing repositories and signing config are left alone | `registry/.env`, `registry/.ak-token`, `registry/out/`, podman volumes |
| `keys` | seconds | no-op, keeps existing keys | `signing/keys/` |
| `publish-keys` | seconds | skips unchanged files; a changed file is deleted and re-uploaded | `raw-edge-keys` |
| `base` | about 3.5 to 4 min | skipped while `localhost/rocky-bootc-base:10` exists (`make base-rebuild` forces it) | local image, `oci-bootc/rocky-bootc-base` |
| `rpm` | about 7 s build and sign | rebuilds; the upload answers 409 for existing files and keeps them | `rpms/out/`, `rpm-edge-site` |
| `image` | 27 s, then 8 s per further release | same | local images `rocky-edge:10.2-3`, `:10.2-4` |
| `push` | 1-2 s per image, 1 s per signature | same; re-points `:10` at `REL` | `oci-bootc/rocky-edge` |
| `unsigned-test` | seconds | same | `oci-bootc/rocky-edge:unsigned-test` |
| `sign`, `verify` | seconds | `sign` is a no-op when signatures verify | `.sig` tags in `oci-bootc` |
| `vm-install` | 65 s (plus the media download once) | always a fresh disk | `deploy/cache/`, `deploy/state/` |
| `vm-boot` | 25 s to ssh, 61 s more to node Ready | reuses a running VM | `deploy/state/boot-serial.log`, `timings.log` |
| `vm-verify` | seconds | read-only | none |
| `vm-upgrade-unsigned` | seconds | restores `:10` each time | moves and restores `:10` |
| `vm-upgrade` | 6 s pull and stage, 20 s reboot | upgrades to whatever `PROMOTE_FROM` is | `:10`, the node's deployments |
| `vm-rollback` | about 101 s reboot | swaps back and forth | the node's deployments |

**First-run costs.** The base build pulls about 800 MB of RPMs through the Artifact Keeper
proxy repositories, and `vm-install` downloads the installer's 750 MB stage2 once into
`deploy/cache/`. A cold `make all` takes roughly 6 to 8 minutes on a fast connection, most of
it the base build; that total is estimated from the per-step times, not measured as one run.

## 1. `make registry-up`

Runs `registry/up.sh` then `registry/bootstrap.sh`.

- `up.sh` copies `.env.example` to `registry/.env` on the first run and fills in the
  secrets Artifact Keeper refuses to start without (`JWT_SECRET`, `AK_WEBHOOK_SECRET_KEY`,
  a random `ADMIN_PASSWORD`), starts the stack with `podman compose`, and waits for
  `/readyz` (about 60 s cold).
- `bootstrap.sh` creates the 12 repositories (all `is_public: true`), creates a server-side
  GPG key and turns on `sign_metadata` for `rpm-edge-site`, mints or reuses a CI token in
  `registry/.ak-token`, and writes `registry/out/edge.repo`, `edge.repo.in` and
  `README-urls.md`. Existing repositories and signing config are detected and left alone.

Expect: the web UI at <http://localhost:30080> (user `admin`, password in `registry/.env`)
and a re-run that reports `repodata signing already enabled on rpm-edge-site (key 56f1a82f...)`.

**If it fails:** `podman compose -p artifact-keeper logs backend`; safe to re-run. A backend
that exits at start is the secrets check, see
[Troubleshooting](../troubleshooting.md#backend-exits-on-ak_webhook_secret_key-or-jwt_secret).

## 2. `make keys`

Runs `signing/gen-keys.sh`. Creates, if missing:

- a cosign key pair (`signing/keys/cosign.key`, `.pub`; empty password, PoC only),
- an RSA 4096 sign-only RPM GPG key in a throwaway `GNUPGHOME` (`signing/keys/gnupg`),
- public copies in `signing/keys/pub/`, plus the Rancher and EPEL 10 vendor keys and a
  reference copy of Rocky's key from the base image.

**If it fails:** the output names the missing tool or download; safe to re-run, existing
keys are kept. Deleting `signing/keys/` makes new keys, and every image must be re-signed.

## 3. `make publish-keys`

Runs `signing/publish-keys.sh`: uploads `edge-cosign.pub`, `RPM-GPG-KEY-edge`,
`RPM-GPG-KEY-Rancher` and `RPM-GPG-KEY-EPEL-10` to the generic repository `raw-edge-keys`,
then downloads each one anonymously and compares bytes. The keys are served at
`http://<host>:30080/api/v1/repositories/raw-edge-keys/download/<file>`.

**If it fails:** usually an expired CI token (re-run `make registry-up` to mint one) or a
[write-once conflict](../troubleshooting.md#http-409-on-upload); safe to re-run.

## 4. `make base`

Runs `base/build.sh` (about 3.5 to 4 min). It stages the vendored RESF `rocky-bootc` recipe
plus our `Containerfile` and an Artifact-Keeper-only `.repo` file into `base/.work/ctx`, then
builds rootless:

- the builder is `localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`;
- its `/etc/yum.repos.d` is replaced with the three `rpm-rocky10-*` repositories (gpgcheck
  and repo_gpgcheck on) before the first `dnf install`, so the whole rootfs comes through
  Artifact Keeper;
- `MANIFEST=minimal` (242 RPMs, 792 MB), not upstream's `standard`, which would enable
  automatic fetch-apply-reboot;
- `--no-cache` always (the final stage deletes its own input archive).

Then `bootc container lint`, push (`--remove-signatures`) to
`oci-bootc/rocky-bootc-base:10-YYYYMMDD` and `:10`, and cosign-sign the digest.

**If it fails:** the build log is on the terminal; safe to re-run (`make base-rebuild` if a
broken local image exists). A push error `Would invalidate signatures` is covered in
[Troubleshooting](../troubleshooting.md#would-invalidate-signatures-on-push).

## 5. `make rpm`

`rpms/build.sh` builds `edge-site-config` releases 3 and 4 with `rpmbuild` in a Rocky 10
container (dnf restricted to the Artifact Keeper proxy repositories, gpg-checked), signs them
with `rpmsign`, and fails unless `rpm -K` prints `digests signatures OK`. `rpms/upload.sh`
PUTs them to `rpm-edge-site` and checks that the server-generated `primary.xml.gz` lists them.
Re-uploading an existing file name returns HTTP 409 and is left as is: bump the release
instead of rebuilding.

**If it fails:** safe to re-run; output in `rpms/out/`.

## 6. `make image push`

`make image` runs `image/setup-host.sh` (user-level policy, see
[Environment setup](../environment.md#files-the-scripts-write-under-configcontainers)) and
builds `localhost/rocky-edge:10.2-3` and `:10.2-4`. The build pulls the base **through the
signature policy**, so an unsigned base stops it. It deletes the base's stock `.repo` files,
installs NetworkManager, openssh-server, bubblewrap, `kernel-modules-extra` (pinned to the
base kernel), `rke2-server` and `rke2-selinux`, then the site RPM in a separate layer,
re-links `/opt` to `var/opt`, copies in the node's `policy.json`, `registries.d` entry and
cosign public key, and fails on any repository or key URL that is not Artifact Keeper or any
`gpgcheck=0`. A smoke test runs the image as a container, and
`bootc container lint --fatal-warnings` must pass (13 passed, 1 skipped).

`make push` pushes both tags, cosign-signs each digest, and moves the floating `:10` to
`10.2-3` with a registry-side `skopeo copy` (same digest, so it is covered by the same
signature).

| Step | Time |
|---|---|
| build, OS layer re-run | 27 s |
| build, each further release (OS layer cached) | 8 s |
| push per image (only new layers) | 1-2 s |
| cosign signature per image | 1 s |

!!! warning "`make push` re-points `:10`"
    `make push` always moves `:10` to `REL` (default 3). Running it after a day-2 promote
    moves the fleet's tag back; the next `bootc upgrade` on a node would then go back to
    the older release. Use `make promote REL=N` to move the tag deliberately.

**If it fails:** safe to re-run. A base rejected by the policy is
[`A signature was required`](../troubleshooting.md#a-signature-was-required-but-no-signature-exists).

## 7. `make unsigned-test`

Builds `rocky-edge:unsigned-test` (release 4 plus the label `edge.test=unsigned`, so it has
a new digest) and pushes it **without** signing. It is the input to both negative VM tests.
A plain retag of a signed image would not work as a negative test: signatures belong to
digests, so an identical image under a new tag is still signed.

**If it fails:** safe to re-run.

## 8. `make sign` and `make verify`

`make sign` (re)signs the base and every release tag; it is a no-op when the digests already
verify. `make verify` runs `signing/verify.sh`, which checks that:

- every public key is served anonymously and matches the local copy;
- `cosign verify` passes for each release tag and for `:10`, and fails for the negative tags;
- the build-host policy admits the signed base and rejects the unsigned one;
- `repomd.xml.asc` verifies for `rpm-edge-site` (Artifact Keeper's key) and for the proxied
  Rocky and RKE2 repositories (vendor keys);
- `rpm -K` passes for the signed RPMs.

**If it fails:** the failing check is printed; both are read-only apart from new signatures
and safe to re-run.

## 9. `make vm-install`

`deploy/vm-install.sh` (65 s with KVM, about 10 min under TCG):

1. Fetches and sha256-checks the Rocky 10.2 pxeboot `vmlinuz`, `initrd.img` and stage2
   `install.img` into `deploy/cache/` (first run only).
2. Renders `deploy/ks.cfg.in` into `deploy/state/www/ks.cfg` with your public key, and serves
   it plus the stage2 on port 8000.
3. Creates a fresh 40 GB qcow2 and OVMF vars and starts QEMU headless with
   `inst.ks=http://10.0.2.2:8000/ks.cfg`.
4. Follows the installer's milestones on the serial console: `Starting installer`,
   `Installing the software`, `Performing post-installation`, `Installation complete`.

During the install, kickstart `%pre` writes the installer's `policy.json` (default `reject`,
cosign signature required for `rocky-edge`), fetches the key from `raw-edge-keys`, and
`ostreecontainer` pulls `10.0.2.2:30080/oci-bootc/rocky-edge:10`.

**Negative test:** `make vm-install IMAGE=rocky-edge:unsigned-test` must stop with

```text
error: Performing deployment: Preparing import: Fetching manifest: failed to
invoke method OpenImage: A signature was required, but no signature exists
```

`vm-install.sh` watches for that and aborts in about 45 s (the installer would otherwise wait
for ENTER forever).

**If it fails:** the serial log is `deploy/state/install-serial.log`; re-running is safe and
always starts from a fresh disk. See
[Troubleshooting](../troubleshooting.md#vm-install-times-out).

## 10. `make vm-boot`

Boots the disk in the background with ssh forwarded to port 2222, waits for ssh (25 s KVM,
52 s TCG) and for the RKE2 node to be Ready (another 61 s KVM, about 4.5 min TCG), then
prints `bootc status` (image `10.0.2.2:30080/oci-bootc/rocky-edge:10`, version `10.2-3`),
`getenforce` (`Enforcing`), the insecure-registry drop-ins and the node's signature policy.

**If it fails:** `deploy/state/boot-serial.log`, and `deploy/state/rke2-server-journal.log`
when the node never gets Ready; safe to re-run (it reuses a running VM). A node stuck
NotReady is [`/opt/cni`](../troubleshooting.md#rke2-never-ready-mkdir-optcni-read-only-file-system).

## 11. `make vm-verify`

Waits until `rke2-server` is active and every `nginx-demo` pod is Running and Ready, then
checks that the pod's image digest (`docker.io/library/nginx:alpine`) exists in Artifact
Keeper's `oci-dockerhub-proxy`. That is the proof the workload came through the registry:
RKE2's `registries.yaml` mirrors all of `docker.io` to `http://10.0.2.2:30080` with a
`rewrite` to `oci-dockerhub-proxy/$1`. The Deployment's label
`edge-site/config-release=N` shows which site-config release is live.

**If it fails:** read-only, re-run it; right after an upgrade or rollback the Deployment may
still be rolling out.

## 12. `make vm-upgrade-unsigned` (day-2 negative)

Copies `rocky-edge:unsigned-test` onto `:10` (with `skopeo copy --insecure-policy`, because
the build-host policy would refuse it too), runs `bootc upgrade` on the node, and requires
it to fail:

```text
error: Upgrading: Preparing import: Fetching manifest: failed to invoke method OpenImage:
A signature was required, but no signature exists
```

It then checks that nothing is staged, the node is still on its image and `rke2-server` is
active, and restores `:10` to the signed digest.

**If it fails:** safe to re-run; if it was interrupted, `make promote REL=3` puts `:10` back.

## 13. `make vm-upgrade` (day 2)

Promotes `rocky-edge:10.2-4` to `:10` (a 1 s registry-side tag copy; no re-signing needed),
runs `bootc upgrade` (`layers needed: 3 (7.8 MB)`, 6 s with KVM), reboots (20 s to ssh) and
asserts that the booted digest is the staged one and the rollback slot holds the old one.
Expect the MOTD to change to `edge-site-config 1.0-4.el10: day-2 update via bootc upgrade`
and, after a `vm-verify`, `nginx-demo ... edge-site/config-release=4`. If the booted digest
does not match, the script prints the `ostree-boot-complete` journal, which is where a failed
finalize shows up.

Override the source with `PROMOTE_FROM=` (empty means just `bootc upgrade` without retagging).

**If it fails:** safe to re-run. Booting the old image again is
[the `bwrap` case](../troubleshooting.md#upgrade-succeeds-but-the-node-boots-the-old-image).

## 14. `make vm-rollback`

`bootc rollback`, reboot (about 101 s to ssh with KVM), and assert that booted and rollback
swapped. The MOTD goes back to `1.0-3.el10: initial site configuration` and, because
`edge-site-manifests.service` re-seeds the RKE2 manifests from the booted image on every boot,
the Deployment goes back to `config-release=3`. Running it a second time swaps forward again.

**If it fails:** safe to re-run; `make vm-clean` and start over at `vm-install` if the disk
is in a state you do not trust.

## Other targets

| Target | What |
|---|---|
| `make preflight` | host checks, see [Environment setup](../environment.md#preflight) |
| `make vm-ssh` | `ssh -p 2222 root@localhost` (key only) |
| `make vm-status` | one-screen summary of the VM and `bootc status` |
| `make vm-stop` | clean ACPI poweroff (about 90 s under TCG) |
| `make vm-clean` | stop and delete `deploy/state/` (`CLEAN_CACHE=1` also drops the media cache) |
| `make promote REL=4` | move `:10` to another release without touching the VM |
| `make registry-down` | stop Artifact Keeper, volumes kept (`registry/down.sh -v` deletes them) |
| `make clean` | remove local build scratch (`base/.work`, `rpms/.work`, `rpms/out`, `image/.work`) |

Every variable in `deploy/lib.sh` (`IMAGE`, `REGISTRY`, `VM_SMP`, `VM_MEM`, `SSH_PORT`,
`SSH_KEY`, `STAGE2`, timeouts, ...) can be overridden on the `make` command line; the full
table is in `deploy/README.md`.
