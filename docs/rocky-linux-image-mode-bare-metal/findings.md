# Findings overview

The three lab logs ([image build](findings-image.md), [deploy](findings-deploy.md),
[signing](findings-signing.md)) record what broke while building this PoC, in the order it
happened. This page is the summary: one row per problem, with the exact message you would
see, why it happens, what this repository does about it, and where the full story is.
For step-by-step fixes by error string, see [Troubleshooting](troubleshooting.md).

## What broke, and the fix

| Symptom (exact message) | Root cause | Fix in this repository | Details |
|---|---|---|---|
| `mkdir /opt/cni: read-only file system`, RKE2 node never Ready | the RESF base keeps `/opt` as a real directory on the read-only composefs root; canal's CNI installer writes `/opt/cni/bin` | edge image re-links `/opt -> var/opt` and adds tmpfiles entries for `/var/opt/cni/bin` | [image log §5](findings-image.md#5-opt-is-read-only-in-the-resf-base-which-breaks-rke2s-cni-found-at-the-vm-gate) |
| `Failed to execute child process "/usr/bin/bwrap" (No such file or directory)`, upgrade boots the old image | ostree rebuilds SELinux policy at finalize inside bubblewrap; the minimal base lacks it and nothing requires it | edge image installs `bubblewrap` and makes the journal persistent | [image log §7](findings-image.md#7-day-2-upgrade-silently-rolled-back-no-bwrap-in-the-base-found-at-the-vm-gate) |
| AVC denials for sshd and NetworkManager on first boot | the `bootc` kickstart command leaves root's `authorized_keys` and `/etc/resolv.conf` mislabelled on Rocky 10.2 | kickstart uses `ostreecontainer` | [deploy log](findings-deploy.md#install-method-ostreecontainer-vs-the-bootc-kickstart-command) |
| `A signature was required, but no signature exists` although `cosign verify` passes | cosign 3 signs in the Sigstore bundle format via the referrers API; containers-image reads only `.sig` attachments | `signing/lib.sh` passes `--new-bundle-format=false --use-signing-config=false --tlog-upload=false` | [signing log §5](findings-signing.md#cosign-3-needs-the-legacy-format-for-containers-image) |
| `Signature for identity "localhost:30080/oci-bootc/..." is not accepted` | cosign writes a tag-less identity; the default `matchRepoDigestOrExact` rejects it | `signedIdentity: matchRepository` (build host) / `exactRepository` (installer, node) | [signing log §5](findings-signing.md#build-host-verification-imagesetup-hostsh) |
| node pulls `10.0.2.2:30080/...` but the signature names `localhost:30080/...` | signatures record the signer's address for the registry | node and installer policy use `exactRepository` naming the signer's address | [signing log §6](findings-signing.md#6-node-side-verification-in-the-image) |
| unsigned image installs although `--no-signature-verification` was removed | the installer's stock `policy.json` is `insecureAcceptAnything`; the flag does not change enforcement | kickstart `%pre` writes a `reject` policy; the image ships one for `bootc upgrade` | [signing log §7](findings-signing.md#7-kickstart) |
| `Error: Copying this image would require changing layer representation, which we cannot do: "Would invalidate signatures"` | an image pulled through the policy carries its signatures in local storage | `podman push --remove-signatures`, then sign the digest | [signing log §5](findings-signing.md#gotcha-pushing-an-image-that-was-pulled-through-the-policy) |
| an "unsigned" negative-test tag still verifies | signatures belong to digests; a copy with the same digest is signed | negative-test images change the digest (`--format v2s2`, an extra label) | [signing log §5](findings-signing.md#gotcha-unsigned-copies-that-are-still-signed) |
| `Package ... is not signed` / `Error: GPG check FAILED`; `repomd.xml GPG signature verification error: Signing key not found` | an unsigned RPM; a `repo_gpgcheck=1` repository without the right `gpgkey=` | RPMs are `rpmsign`ed; `.repo` files list the vendor, edge and Artifact Keeper keys | [signing log §4](findings-signing.md#4-repo-files) |
| `gpg: packet(6) with unknown version 6` | Rocky 10's key file includes an OpenPGP v6 key that GnuPG 2.4 cannot parse (rpm and dnf can) | `signing/verify.sh` uses only the first (v4) block | [signing log §1](findings-signing.md#1-keys-signinggen-keyssh) |
| backend exits at start; `JWT_SECRET` rejected | the compose defaults are a denylisted `JWT_SECRET` and an `AK_WEBHOOK_SECRET_KEY` that does not decode to 32 bytes | `registry/up.sh` generates both and an `ADMIN_PASSWORD` | [Artifact Keeper notes](artifact-keeper-notes.md#docs-vs-reality) |
| `HTTP 404 Repository not found` on the documented RPM upload | the guide's `/api/artifacts/rpm/<repo>` route does not exist in v1.10.2 | `PUT /rpm/<key>/packages/<file>.rpm` | [Artifact Keeper notes](artifact-keeper-notes.md#docs-vs-reality) |
| HTTP 409 on a second upload | hosted RPM and generic repositories are write-once per file name | bump the RPM release; for keys, `DELETE` (needs `delete:artifacts`) then `PUT` | [image log §3](findings-image.md#3-site-rpm-edge-site-config), [signing log §2](findings-signing.md#2-keys-in-the-registry-raw-edge-keys-generic-repo) |
| `/general/<key>/<file>` returns the web UI's HTML 404 | the stock Caddyfile does not route `/general/*` | download through `/api/v1/repositories/<key>/download/<file>` | [signing log §2](findings-signing.md#2-keys-in-the-registry-raw-edge-keys-generic-repo) |
| second base build fails on a missing `oci-archive:./out.ociarchive` | the recipe's final stage deletes its own input; a cached builder stage does not regenerate it | `base/build.sh` always passes `--no-cache` and runs from the context directory | [image log §2](findings-image.md#2-base-image-the-resf-recipe-builds-rootless) |
| `pinging container registry localhost:30080: Get "https://localhost:30080/v2/"` | the registry is plain HTTP | user-level `registries.conf.d` drop-in marks it insecure | [image log §4](findings-image.md#4-edge-image) |
| nodes reboot on their own after building from upstream defaults | the recipe's default `standard` manifest enables `bootc-fetch-apply-updates.timer` through a `/usr` symlink | `MANIFEST=minimal` | [image log §2](findings-image.md#2-base-image-the-resf-recipe-builds-rootless) |

## Verification gates

The lab logs refer to the gates of the [original plan](plan.md) by number.

| Gate | What had to be true |
|---|---|
| 1 | Artifact Keeper works end to end: dnf through a proxy repository, RPM upload and repodata, OCI push and pull, the quay.io proxy |
| 2 | the base image builds rootless, `bootc container lint` passes, and it is pushed to `oci-bootc` |
| 3 | the edge image builds with no repository URL outside Artifact Keeper, lint passes, and it is pushed |
| 4 | an unattended kickstart install completes; first boot shows the Artifact Keeper image in `bootc status`, SELinux enforcing, the node Ready and a workload Running from an image pulled through the Docker Hub proxy |
| 5 | day 2: a new site-config release reaches the node with `bootc upgrade`, and `bootc rollback` returns to the previous image |
| 6 | an unsigned image fails `podman build FROM`, the kickstart install and `bootc upgrade`, each with the signature error |
| 7 | signed images pass all three |
| 8 | `rpm -K`, dnf `gpgcheck=1` and `repo_gpgcheck=1` succeed |
| 9 | the full install, boot, verify, upgrade, rollback sequence runs with KVM on the signed images, with timings recorded |
