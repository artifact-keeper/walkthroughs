# Troubleshooting

One section per error message or symptom, with the cause, the fix and a link to the full
record. The [Findings overview](findings.md) has the same problems as one table.

## A signature was required, but no signature exists

```text
Source image rejected: A signature was required, but no signature exists
error: Performing deployment: Preparing import: Fetching manifest: failed to
invoke method OpenImage: A signature was required, but no signature exists
```

**Cause.** A `policy.json` requires a cosign signature for this repository and
containers-image found none it can read. Either the image really is unsigned (expected for
`unsigned-test` and `rocky-bootc-base:unsigned`), or it was signed with cosign 3's default
Sigstore bundle format, which lands in the OCI referrers API where podman, skopeo, bootc and
the installer do not look (`cosign verify` still passes).

**Fix.** Sign with `make sign` (or `signing/sign-image.sh`), which uses the legacy
`sha256-<digest>.sig` format. If you call cosign yourself, pass
`--new-bundle-format=false --use-signing-config=false --tlog-upload=false`. Check with
`skopeo list-tags` that a `sha256-<digest>.sig` tag exists for the digest you pull.

Details: [signing log §5](findings-signing.md#cosign-3-needs-the-legacy-format-for-containers-image).

## Signature for identity ... is not accepted, or invalid signature when validating ASN.1

```text
Source image rejected: Signature for identity "localhost:30080/oci-bootc/sigtest" is not accepted
Source image rejected: cryptographic signature verification failed: invalid signature when validating ASN.1 encoded signature
```

**Cause.** The first: the policy uses the default `signedIdentity` (`matchRepoDigestOrExact`),
which rejects the tag-less identity cosign writes, or an `exactRepository` rule names a
different repository than the one the signer pushed to. The second: the image was signed
with a different key than the one in `keyPath`.

**Fix.** Use `matchRepository` when signer and client see the registry under the same name,
and `exactRepository` with the signer's name (`localhost:30080/oci-bootc/<image>`) when they
do not, as on the node. For the key error, check that `keyPath` points at the current
`edge-cosign.pub` (the node and installer copies come from `raw-edge-keys` and from the
image) and re-sign with `make sign` if the key was regenerated.

Details: [signing log §5](findings-signing.md#build-host-verification-imagesetup-hostsh),
[§6](findings-signing.md#6-node-side-verification-in-the-image).

## HTTP 409 on upload

**Cause.** Hosted RPM and generic repositories are write-once per file name: a second `PUT`
of the same name answers 409 and keeps the stored file, even if your bytes differ (rpmbuild
output is not reproducible).

**Fix.** For RPMs, bump the release (`RELEASES=5 rpms/build.sh`); `rpms/upload.sh` reports
existing files and moves on. To replace a generic file, `DELETE` it first, which needs the
`delete:artifacts` scope (the CI token does not have it; `signing/publish-keys.sh` uses the
admin login for that one call).

Details: [image log §3](findings-image.md#3-site-rpm-edge-site-config),
[signing log §2](findings-signing.md#2-keys-in-the-registry-raw-edge-keys-generic-repo).

## HTTP 404 on the documented RPM upload route

```text
curl -F file=@pkg.rpm http://localhost:8080/api/artifacts/rpm/<repo>   ->  HTTP 404 Repository not found
```

**Cause.** The route in Artifact Keeper's `guides/system-packages.mdx` does not exist in
v1.10.2, and the guides use port 8080 while the compose stack serves on 30080.

**Fix.** `PUT /rpm/<key>/packages/<file>.rpm` (or `POST /rpm/<key>/upload`) on port 30080, with
the API token as the basic-auth password:
`curl -u "admin:$(cat registry/.ak-token)" -T foo.rpm http://localhost:30080/rpm/rpm-edge-site/packages/foo.rpm`.

Details: [Artifact Keeper notes](artifact-keeper-notes.md#docs-vs-reality).

## Backend exits on AK_WEBHOOK_SECRET_KEY or JWT_SECRET

**Cause.** The compose defaults are fatal. `JWT_SECRET=change-me-in-production-please` is on
the backend's placeholder denylist, and `AK_WEBHOOK_SECRET_KEY=REPLACE_ME_...` must
base64-decode to exactly 32 bytes or the backend exits. Without `ADMIN_PASSWORD` the API is
also locked until the generated password is changed.

**Fix.** Let `registry/up.sh` create `registry/.env`; it generates both secrets
(`openssl rand -base64 48` / `-base64 32`) and a random `ADMIN_PASSWORD`. If you wrote `.env`
yourself, regenerate those values and run `make registry-up` again.

Details: [Artifact Keeper notes](artifact-keeper-notes.md#docs-vs-reality).

## AVC denials on first boot (bootc kickstart command)

**Symptom.** After an install with the kickstart `bootc` command, SELinux AVC denials block
`sshd` and `NetworkManager` on first boot, so the node is unreachable over ssh.

**Cause.** On Rocky 10.2 the `bootc` command (`bootc install to-filesystem`) left root's
`authorized_keys` labelled `var_t` and `/etc/resolv.conf` labelled `etc_t`. A `%post`
`restorecon -RF` did not fix it.

**Fix.** Use `ostreecontainer --url=<registry>/<image> --transport=registry`, as
`deploy/ks.cfg.in` does.

Details: [deploy log](findings-deploy.md#install-method-ostreecontainer-vs-the-bootc-kickstart-command).

## RKE2 never Ready: mkdir /opt/cni read-only file system

```text
Error: failed to generate container "..." spec: failed to generate spec: failed to mkdir "/opt/cni/bin":
  mkdir /opt/cni: read-only file system
```

**Cause.** The RESF base keeps `/opt` as a real directory on the read-only composefs root
instead of the classic `/opt -> var/opt` link. Canal's `install-cni` init container writes the
host CNI plugins to `/opt/cni/bin`. `podman run` and `bootc container lint` cannot see this;
only a booted node does.

**Fix.** In the image: `rm -rf /opt && ln -s var/opt /opt` plus tmpfiles entries
`d /var/opt/cni` and `d /var/opt/cni/bin`. `image/build.sh` asserts the link.

Details: [image log §5](findings-image.md#5-opt-is-read-only-in-the-resf-base-which-breaks-rke2s-cni-found-at-the-vm-gate).

## Upgrade succeeds but the node boots the old image

**Symptom.** `bootc upgrade` reports `Queued for next boot`, but after the reboot `bootc status`
shows the old digest and no staged deployment. On the next boot `ostree-boot-complete` says:

```text
ostree-finalize-staged.service failed on previous boot: Finalizing deployment: Finalizing SELinux policy:
Failed to execute child process "/usr/bin/bwrap" (No such file or directory)
```

**Cause.** Finalizing a staged deployment whose image adds SELinux modules (`rke2-selinux`)
runs `semodule` inside bubblewrap, and the minimal base does not ship `bubblewrap`. A failed
finalize does not stop the shutdown; the boot entry is simply never written.

**Fix.** Install `bubblewrap` in the image, and create `/var/log/journal` (tmpfiles) so the
previous boot's journal survives. `deploy/vm-upgrade.sh` prints the `ostree-boot-complete`
journal when the booted digest is not the staged one.

Details: [image log §7](findings-image.md#7-day-2-upgrade-silently-rolled-back-no-bwrap-in-the-base-found-at-the-vm-gate).

## Would invalidate signatures on push

```text
Error: Copying this image would require changing layer representation, which we cannot do: "Would invalidate signatures"
```

**Cause.** An image pulled through a signature-checking `policy.json` keeps its signatures
in local storage; pushing it in a different layer format would break them.

**Fix.** `podman push --remove-signatures`, then sign the pushed digest (the scripts do both).

Details: [signing log §5](findings-signing.md#gotcha-pushing-an-image-that-was-pulled-through-the-policy).

## vm-install times out

**Where to look.** The installer's serial console is captured in
`deploy/state/install-serial.log`; `vm-install.sh` follows the milestones `Starting installer`,
`Installing the software`, `Performing post-installation`, `Installation complete` in it.

**Common causes.**

- A signature or policy error: `vm-install.sh` detects those and aborts within seconds, see
  [above](#a-signature-was-required-but-no-signature-exists). An installer error the script
  does not recognise ends at `Press ENTER to exit:` in the serial log and waits until
  `INSTALL_TIMEOUT` (2400 s).
- No KVM: under TCG the installer takes about 5 minutes just to start and the whole install
  about 10 minutes. That is normal.
- `STAGE2=mirror` on a slow link: the 750 MB `install.img` comes from dl.rockylinux.org
  (about 250 s at 3 MB/s). The default `STAGE2=local` serves a cached copy.
- Port 8000 already in use, so the kickstart is never served: `make preflight`.

Re-running `make vm-install` is safe; it always creates a fresh disk.

## dnf GPG check FAILED or Signing key not found

```text
Package edge-site-config-1.0-1.el10.noarch.rpm is not signed
Error: GPG check FAILED
Error: Failed to download metadata for repo 'rpm-edge-site': repomd.xml GPG signature verification error: Signing key not found
```

**Cause.** The first: an unsigned RPM (here an early release from before signing) with
`gpgcheck=1`. The second: `repo_gpgcheck=1` on a repository whose `gpgkey=` list does not
include the key that signed `repomd.xml`; for `rpm-edge-site` that is Artifact Keeper's
repodata key, not our RPM key.

**Fix.** Install signed releases (1.0-3 and later). For `rpm-edge-site`, list both keys:
`RPM-GPG-KEY-edge` from `raw-edge-keys` and `http://<host>:30080/rpm/rpm-edge-site/repodata/repomd.xml.key`,
as the generated `registry/out/edge.repo` does.

Details: [signing log §4](findings-signing.md#4-repo-files).
