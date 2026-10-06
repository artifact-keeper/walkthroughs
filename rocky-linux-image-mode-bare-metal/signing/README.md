# signing/ — keys and the trust model

Every artifact an edge node consumes is signed, Artifact Keeper stores the signatures
and the public keys, and every consumer verifies.
There is no `--no-signature-verification`, `gpgcheck=0` or `insecureAcceptAnything`
on any path that touches our content.

## Who signs what

The trust table (who signs, where the signature lives, who verifies) is on the site:
[Architecture, trust model](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/architecture/#trust-model).

## Files

| Path | What |
|---|---|
| `gen-keys.sh` | Idempotent. Creates the cosign key pair and the RPM GPG key in `keys/`, exports public keys to `keys/pub/`, fetches the Rancher and EPEL 10 keys, copies Rocky's key out of the base image (reference only) |
| `publish-keys.sh` | Uploads `edge-cosign.pub`, `RPM-GPG-KEY-edge`, `RPM-GPG-KEY-Rancher`, `RPM-GPG-KEY-EPEL-10` to `raw-edge-keys`, proves anonymous download returns the same bytes, prints the URLs |
| `lib.sh` | cosign flags and helpers shared by the scripts below, `image/push.sh` and `base/build.sh` |
| `sign-image.sh` | Signs `IMAGE:TAG...` by digest (resolves the tag first), then `cosign verify`; skips digests that already verify |
| `verify.sh` | Host-side end-to-end check (keys served, cosign verify of every release tag and of the `:10` float, negative tags unsigned, build-host policy admits/rejects, repodata signatures, `rpm -K`) |
| `keys/` | **gitignored**, mode 700: `cosign.key`, `cosign.pub`, `gnupg/` (throwaway GNUPGHOME with the RPM key), `docker/config.json` (registry auth for cosign), `pub/` |

```bash
make keys           # signing/gen-keys.sh
make publish-keys   # signing/publish-keys.sh
make sign           # (re)sign base + rocky-edge release tags, no-op when already signed
make verify         # signing/verify.sh
```

Public key URLs (anonymous; from the VM use `10.0.2.2`, from a podman build `host.containers.internal`):

```
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/edge-cosign.pub
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-edge
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-Rancher
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-EPEL-10
http://localhost:30080/rpm/rpm-edge-site/repodata/repomd.xml.key      (AK's repodata key)
```

## PoC shortcuts and gotchas

Keys without passphrases, no rotation, no transparency log, plain HTTP: see
[What Artifact Keeper does here](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/artifact-keeper/#what-this-poc-skips-for-production).
The cosign format and identity problems are in the [Findings overview](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/findings/)
and [Troubleshooting](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/troubleshooting/).
