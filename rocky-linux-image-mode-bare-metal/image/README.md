# image/ — the edge OS image

`localhost:30080/oci-bootc/rocky-edge` = the AK-hosted base
(`oci-bootc/rocky-bootc-base:10`) + NetworkManager, openssh-server,
kernel-modules-extra (matched to the base kernel), rke2-server 1.36,
rke2-selinux and `edge-site-config-1.0-<rel>`, with a serial console karg and
`bubblewrap` (needed by ostree to finalize SELinux policy on upgrade; findings section 7),
a persistent journal, and `/opt -> var/opt` (the RESF base ships a read-only `/opt`; RKE2's CNI installer
writes `/opt/cni/bin`, see docs/findings-image.md section 5).

| Tag | Content |
|---|---|
| `rocky-edge:10.2-3` | edge-site-config 1.0-3 (signed baseline), cosign-signed |
| `rocky-edge:10.2-4` | edge-site-config 1.0-4 (signed day-2 demo), cosign-signed |
| `rocky-edge:10` | floating; points at `10.2-3` after `make push`, move it with `make promote REL=4`; covered by the signature of the digest it points at |
| `rocky-edge:unsigned-test` | 10.2-4 rebuilt with label `edge.test=unsigned`, **not signed** (`make unsigned-test`; negative tests) |
| `rocky-edge:10.2-1`, `:10.2-2` | earlier unsigned builds; refused by the policies now |

From the VM the image is `10.0.2.2:30080/oci-bootc/rocky-edge:10` (anonymous pull).

## Signatures

- **Build host verifies the base.** `setup-host.sh` writes a user-level
  `~/.config/containers/policy.json` (a copy of the system policy plus a
  `sigstoreSigned` rule for `localhost:30080/oci-bootc`, key
  `signing/keys/pub/edge-cosign.pub`, `signedIdentity: matchRepository`) and
  `~/.config/containers/registries.d/ak-oci-bootc.yaml` (`use-sigstore-attachments: true`;
  the system yaml files are symlinked alongside, because a user `registries.d` replaces the
  system one). `build.sh` pulls the base without `--tls-verify=false`, so an unsigned or
  wrongly signed base stops the build:
  `Source image rejected: A signature was required, but no signature exists`.
- **dnf verifies everything.** Both repo files have `gpgcheck=1`, and `repo_gpgcheck=1` where
  the metadata is signed; the gate also rejects any `gpgcheck=0` and any `gpgkey=` URL that is
  not on `:30080` or a local `file:///etc/pki/rpm-gpg/` key.
- **The node verifies upgrades.** `rootfs/etc/containers/policy.json` replaces the base's
  (containers-common, `insecureAcceptAnything`): default `reject`; `10.0.2.2:30080/oci-bootc/rocky-edge`
  (and `rocky-bootc-base`) need a cosign signature by `/etc/pki/containers/edge-cosign.pub` with
  `signedIdentity: exactRepository localhost:30080/oci-bootc/<name>` (the signer's name for the repo);
  everything else under `10.0.2.2:30080/oci-bootc` is rejected; local transports are accepted.
  `rootfs/etc/containers/registries.d/ak-oci-bootc.yaml` enables the `.sig` lookup;
  `build.sh` copies the public key into the build context. The insecure-registry drop-in stays
  (plain HTTP).
- **push.sh signs** each pushed `<osver>-<rel>` digest (`signing/sign-image.sh`, cosign legacy
  `.sig` format, no tlog), then moves `:10` with a registry-side `skopeo copy` (no re-signing:
  the signature is bound to the digest). It prints `signed`/`UNSIGNED` per tag.
  `EXTRA_TAGS=unsigned-test` pushes extra local tags without signing.

## Only-Artifact-Keeper property

- `FROM` is the Artifact Keeper copy of the base, never an external registry.
- The base's stock `/etc/yum.repos.d/*.repo` are deleted; dnf runs with
  `--setopt=reposdir=/tmp/build-repos` (repos at `host.containers.internal:30080`).
- The image ships `/etc/yum.repos.d/edge.repo` with the same repos at `10.0.2.2:30080`
  (the edge node's view of the registry).
- A `RUN` step fails the build if any `baseurl`/`mirrorlist`/`metalink`/`gpgkey` URL in
  `/etc/yum.repos.d` is not on `:30080/` (or a local `file:///etc/pki/rpm-gpg/` key), or if any
  repo has `gpgcheck=0`; `build.sh` checks again from outside.

## Files

| Path | What |
|---|---|
| `Containerfile` | two install layers: OS+RKE2 (cached across site releases), then edge-site-config only |
| `rootfs/usr/lib/bootc/kargs.d/10-console.toml` | `console=tty0 console=ttyS0,115200n8` |
| `rootfs/usr/lib/tmpfiles.d/50-edge-image.conf` | tmpfiles entries for package-owned `/var` dirs (keeps lint warning-free) and `/var/opt/cni/bin` |
| `rootfs/etc/containers/policy.json` | node signature policy (default reject, cosign key required for `rocky-edge`) |
| `rootfs/etc/containers/registries.d/ak-oci-bootc.yaml` | `use-sigstore-attachments` for `10.0.2.2:30080/oci-bootc` |
| `setup-host.sh` | user-level (no sudo): insecure-registry drop-in for `localhost:30080`, `policy.json` requiring the edge cosign signature for `localhost:30080/oci-bootc`, `registries.d` attachment lookup |
| `build.sh` | renders repo files, copies the cosign public key into the context, builds `localhost/rocky-edge:<osver>-<rel>` (or `LOCAL_TAG`, `EXTRA_LABEL`), repo/gpg check, smoke test incl. policy files and imported keys, `bootc container lint --fatal-warnings` |
| `push.sh` | pushes and cosign-signs `<osver>-<rel>` tags (plus unsigned `EXTRA_TAGS`), `skopeo copy` for the floating `:10`, prints digest + signed/UNSIGNED |

## Usage

```bash
make image            # builds releases 3 and 4 (SITE_RELEASE=N image/build.sh)
make push             # pushes + signs 10.2-3, 10.2-4; :10 -> 10.2-3
make unsigned-test    # builds + pushes rocky-edge:unsigned-test, NOT signed
make promote REL=4    # :10 -> 10.2-4 (what deploy/vm-upgrade.sh also does)
```

Note: `make push` always re-points `:10` at `REL` (default 3), so running it
after a day-2 promote rolls the floating tag back. Timings: [Timings](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/timings/#build-side-no-vm).
