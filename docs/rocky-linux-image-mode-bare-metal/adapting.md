# Adapting this to your environment

The PoC takes shortcuts that make sense on one machine: three names for one registry,
plain HTTP, a QEMU VM instead of hardware, keys without passphrases, an internet uplink.
This page lists what to change for each, and which parts depend on Artifact Keeper
specifically.

## Use one DNS name

Here the registry is `localhost:30080` on the host, `host.containers.internal:30080` in
builds and `10.0.2.2:30080` on the edge node (a QEMU VM in this PoC); see
[Two views of the same registry](architecture.md#two-views-of-the-same-registry). Give it one
name that resolves everywhere, for example `registry.example.internal`, and:

- the `@HOST@` rendering of `registry/out/edge.repo.in` collapses to one `.repo` file;
- cosign records the same name the nodes pull from, so every `policy.json` can use
  `signedIdentity: matchRepository` and drop the `exactRepository` mapping in
  `image/rootfs/etc/containers/policy.json` and `deploy/ks.cfg.in`;
- `REGISTRY`, `HOST_REGISTRY` and `KEY_URL` in `deploy/lib.sh` become the same host.

## Turn on TLS

Signatures already protect content end to end. TLS adds confidentiality and protects the
unsigned parts: tag-to-digest resolution, EPEL and k3s metadata, and the key download in
`%pre`. It touches every place the registry address or its plain-HTTP status appears:

| File | Change |
|---|---|
| `registry/compose/compose.override.yml` (Caddy) | serve the real name on 443 with a certificate clients trust (an internal CA is fine; an IP-only name needs an IP SAN) |
| `registry/bootstrap.sh` | `https://` in the generated `edge.repo` / `edge.repo.in` `baseurl=` and `gpgkey=` lines |
| `base/build.sh`, `image/build.sh` | the rendered build-time `.repo` files; drop `--tls-verify=false` |
| `image/setup-host.sh` | drop the `insecure = true` drop-in; the policy scope uses the new name |
| `signing/lib.sh`, `signing/sign-image.sh`, `signing/verify.sh`, `image/push.sh` | drop `--allow-http-registry` / `--allow-insecure-registry` / `--tls-verify=false`; the signed identity is the new name |
| `image/rootfs/etc/containers/policy.json`, `registries.d/ak-oci-bootc.yaml` | scopes and `signedIdentity` under the new name |
| `rpms/edge-site-config/registries.yaml` | `https://` mirror endpoint (a new `edge-site-config` release, since uploads are write-once) |
| `rpms/edge-site-config/50-artifact-keeper.conf` | remove the insecure-registry drop-in |
| `deploy/ks.cfg.in`, `deploy/lib.sh` | `%pre`: no insecure drop-in, `https://` key URL, the CA certificate added to the installer's trust store; `ostreecontainer --url` with the new name |
| the image | the CA certificate in `/etc/pki/ca-trust/source/anchors/` if it is not a public CA |

## Real hardware via PXE/iPXE

The QEMU harness already boots the installer the way a PXE server would: no ISO, just the
Rocky pxeboot `vmlinuz` and `initrd.img`, a stage2 and a kickstart over HTTP. On hardware,
what replaces QEMU's `-kernel`, `-initrd` and `-append`:

- a DHCP server pointing UEFI clients at an iPXE binary (or a GRUB network image);
- an iPXE script that does the same as the QEMU line:

    ```text
    #!ipxe
    kernel http://boot.example.internal/rocky/10.2/vmlinuz inst.stage2=http://boot.example.internal/rocky/10.2/os/ inst.ks=http://boot.example.internal/ks/edge.cfg inst.text
    initrd http://boot.example.internal/rocky/10.2/initrd.img
    boot
    ```

- the cached media from `deploy/cache/` (`deploy/fetch-media.sh` checks them against
  `.treeinfo`) and the rendered kickstart on that HTTP server;
- a kickstart rendered per site or per node (`NODE_HOSTNAME`, the disk layout:
  `clearpart --all` wipes every disk the installer sees, so name the target disk with
  `ignoredisk --only-use=`), with `console=` matching the hardware.

## Production keys

- Protect the cosign key with a passphrase, or keep it in a KMS or HSM (`--key awskms://...`,
  `gcpkms://...`, `hashivault://...`, `pkcs11:`); same for the RPM key (a smartcard or a
  signing service rather than a plain `GNUPGHOME`).
- Pin the cosign key's fingerprint in the kickstart, or embed the key in the kickstart served
  by a trusted install server, instead of trusting the first download; see
  [Root of trust](artifact-keeper.md#root-of-trust).
- Rotate by shipping the new public key in an image signed with the old key: sign new
  releases with both keys (cosign allows several signatures per digest), let every node
  upgrade to an image whose `policy.json` accepts the new key, then stop signing with the old
  one and drop it from the policy. The key files must stay image-managed `/etc` files (the
  kickstart `%post` never overwrites them), or the 3-way `/etc` merge will keep the old copy.

## Air-gap

- Block egress from the nodes at the network. RKE2's generated containerd `hosts.toml` keeps
  `registry-1.docker.io` as the fallback behind the Artifact Keeper mirror, so a mirror miss
  quietly goes to the internet if it can.
- Pre-warm the proxy repositories (or convert them to hosted repositories filled by a
  transfer process): every RPM, the builder image and every RKE2 system image must be in
  Artifact Keeper before the link goes away.
- Stop installing by floating tag: install by digest and promote by digest.

## Using another registry instead of Artifact Keeper

Most of the design is registry-neutral: bootc images, cosign `.sig` attachments,
`policy.json`, dnf repositories with signed metadata. The Artifact Keeper-specific parts are:

- **Path-based OCI repositories.** Images live at `host:30080/<repo>/<image>`. containerd
  mirrors are host-level, so RKE2's `registries.yaml` needs a `rewrite` to
  `oci-dockerhub-proxy/$1`; a registry with host-level proxies (or a different path scheme)
  needs a different mirror entry.
- **The generic repository download route.** Keys are served from
  `/api/v1/repositories/raw-edge-keys/download/<file>`; any static HTTP location works, but
  `KEY_URL` and the `gpgkey=` URLs change.
- **The repodata signing API.** `registry/bootstrap.sh` creates a server-side key and turns on
  `sign_metadata` for `rpm-edge-site`. Elsewhere, run `createrepo_c` and sign `repomd.xml`
  yourself, or use that registry's equivalent.
- **The bootstrap and upload calls** (`registry/bootstrap.sh`, `rpms/upload.sh`,
  `signing/publish-keys.sh`) use Artifact Keeper's REST API; the OCI side uses only the
  standard registry API.
