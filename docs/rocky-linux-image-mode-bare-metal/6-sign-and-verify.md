# Step 6: Sign everything and verify everywhere

Without signatures, every consumer in this pipeline would accept any image the registry handed
out. That is fine for a lab and not acceptable for a fleet. This page closes that gap. The rule
is simple: Artifact Keeper stores the signatures and the public keys next to the artifacts, and
every consumer verifies.

**Make targets:** `make keys`, `make publish-keys`, `make sign` and `make verify`, plus
`make unsigned-test` for the negative tests. The scripts are in
[`signing/`](https://github.com/artifact-keeper/walkthroughs/tree/main/rocky-linux-image-mode-bare-metal/signing).

## What gets signed, and who checks it

| Artifact | Signed by | Signature lives in | Verified by |
|---|---|---|---|
| `edge-site-config` RPM | your GPG key, `rpmsign` in the build container | the RPM header | dnf `gpgcheck=1` during the image build |
| `rpm-edge-site` repodata | Artifact Keeper's managed key | `repodata/repomd.xml.asc` | dnf `repo_gpgcheck=1` |
| Proxied Rocky and RKE2 RPMs | the vendors | RPM headers and upstream `repomd.xml.asc`, passed through the proxy | dnf `gpgcheck=1`, `repo_gpgcheck=1` |
| Base and edge images | your cosign key, by digest, after every push | `oci-bootc`, as a `sha256-<digest>.sig` tag | `policy.json` (the containers-image trust policy) on the build host, in the installer, and on the node |
| Public keys | n/a | the generic repository `raw-edge-keys` | fetched by the build and the kickstart, and shipped in the image |

`make keys` creates a cosign key pair and an RPM GPG signing key under `signing/keys/`
(without passphrases; this is a proof of concept), and `make publish-keys` uploads the public
halves and the vendor keys to `raw-edge-keys`, then downloads each one anonymously to check it.

Because uploads are write-once, the signed rebuild got new release numbers: `edge-site-config`
1.0-3 and 1.0-4, and images `rocky-edge:10.2-3` and `10.2-4`. The unsigned 10.2-1 and 10.2-2
from the dry run stay in the registry as images the policy now refuses, which turned out to be
a convenient test fixture. The [trust model](architecture.md#trust-model) page has the long
form of the table above.

## What Artifact Keeper does here

Two things happen natively. Artifact Keeper signs the repodata of a hosted RPM repository with
a key you create through its signing API, and it serves `repomd.xml.asc` and
`repomd.xml.key`. Its proxies also pass upstream `repomd.xml.asc` through byte for byte, so
the Rocky and RKE2 repositories get `repo_gpgcheck=1` without any extra work. The repodata
signatures expire after seven days and are re-signed on request, which is good to know if you
mirror them.

For images, Artifact Keeper stores whatever cosign pushes right next to the image, and its
generic repository serves the public keys over anonymous HTTP. So image signing stays in your
pipeline with cosign, and Artifact Keeper is the place the signatures and keys live. The
[what Artifact Keeper does here](artifact-keeper.md) page spells out each role.

## The cosign format problem

cosign 3 defaults to a new signature format attached through the OCI referrers API (a newer way
of hanging metadata off an image). Artifact Keeper stored it correctly and `cosign verify`
passed, but podman, skopeo, bootc and Anaconda all said
`A signature was required, but no signature exists`. This was confusing for a while. It turns
out the containers-image stack still reads only the older format, the `sha256-<digest>.sig`
tag. So [`signing/lib.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/signing/lib.sh) signs with the deprecated flags, and the
deprecation warning is the real risk in this design:

```console
$ cosign sign --yes --key signing/keys/cosign.key --allow-http-registry --allow-insecure-registry \
    --tlog-upload=false --new-bundle-format=false --use-signing-config=false \
    localhost:30080/oci-bootc/rocky-edge@sha256:d4f3ec69bbd3...
Flag --new-bundle-format has been deprecated, this will be the only supported format in future versions
Pushing signature to: localhost:30080/oci-bootc/rocky-edge
```

Sign by digest, never by tag. Pin cosign (3.1.3 works) until containers-image reads the new
format. `podman push --sign-by-sigstore-private-key` writes the same older format natively;
the proof of concept has not switched to it yet, but it is the obvious next move. The
[signing notes](findings-signing.md) have the referrers output, the `cosign tree` view, and
how the signatures show up in Artifact Keeper.

## The policy that enforces it

The node ships this in `/etc/containers/policy.json`, with the public key at
`/etc/pki/containers/edge-cosign.pub` and a `registries.d` entry that turns on
`use-sigstore-attachments` for the registry. The default is `reject`, with one exception for
registry pulls of the edge image:

```json title="image/rootfs/etc/containers/policy.json (abridged)"
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "10.0.2.2:30080/oci-bootc/rocky-edge": [{
        "type": "sigstoreSigned",
        "keyPath": "/etc/pki/containers/edge-cosign.pub",
        "signedIdentity": {"type": "exactRepository",
                           "dockerRepository": "localhost:30080/oci-bootc/rocky-edge"}
      }]
    }
  }
}
```

Two lines in there are not obvious. `signedIdentity` is required because cosign records a
tag-less identity that the default matching rule never accepts. And it names
`localhost:30080`, which is the signer's view of the registry, not `10.0.2.2:30080`, which is
the node's view. In production you would give the registry one DNS name everywhere, and this
collapses to `matchRepository` (see [Next steps](next-steps.md#use-one-dns-name)). The real
file, [`image/rootfs/etc/containers/policy.json`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/image/rootfs/etc/containers/policy.json),
also keeps local transports such as `containers-storage` open, which the excerpt leaves out.

## The installer and the build host

The kickstart writes the same three files in `%pre` before `ostreecontainer` runs, fetching
the public key from Artifact Keeper:

```bash title="deploy/ks.cfg.in, %pre (excerpt, rendered)"
mkdir -p /etc/containers/registries.conf.d /etc/containers/registries.d /etc/pki/containers
# Verification key, fetched from Artifact Keeper (raw-edge-keys, anonymous).
curl -fsS --retry 5 --retry-delay 3 -o /etc/pki/containers/edge-cosign.pub \
  "http://10.0.2.2:30080/api/v1/repositories/raw-edge-keys/download/edge-cosign.pub"
grep -q 'BEGIN PUBLIC KEY' /etc/pki/containers/edge-cosign.pub
# Look for cosign's sha256-<digest>.sig attachments next to the image.
cat > /etc/containers/registries.d/ak-oci-bootc.yaml <<'EOR'
docker:
  10.0.2.2:30080/oci-bootc:
    use-sigstore-attachments: true
EOR
# ...then the same policy.json as above.
```

The build host gets a user-level copy of the policy (written by
[`image/setup-host.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/rocky-linux-image-mode-bare-metal/image/setup-host.sh)), so `podman build` `FROM` the base is
checked too.

This led to the finding of this step: **the kickstart's `--no-signature-verification` flag is
not the switch.** With the `%pre` policy in place, an unsigned image is refused even with the
flag added back. With the installer's stock policy, an unsigned image installs fine without it.
The policy file is what enforces signatures, for the installer and for `bootc upgrade` alike.

On the RPM side, the build gate in the
[edge Containerfile](3-add-kubernetes-and-site-config.md#the-edge-containerfile) fails on
`gpgcheck=0` or a missing or foreign `gpgkey`, in addition to foreign repository URLs.

## Proof, both directions

`make unsigned-test` builds `rocky-edge:unsigned-test` (release 4 plus a label, so it has a
new digest) and pushes it without signing. A plain retag of a signed image would not work as a
negative test: signatures belong to digests, so an identical image under a new tag is still
signed. Each consumer was tested with an image that is not signed:

```text
# podman build FROM the unsigned base, on the build host
Error: creating build container: unable to copy from source docker://localhost:30080/oci-bootc/rocky-bootc-base:unsigned:
Source image rejected: A signature was required, but no signature exists

# kickstart install of rocky-edge:unsigned-test, 40 seconds in
error: Performing deployment: Preparing import: Fetching manifest:
failed to invoke method OpenImage: A signature was required, but no signature exists

# bootc upgrade on the node after promoting the unsigned image to :10
error: Upgrading: Preparing import: Fetching manifest:
failed to invoke method OpenImage: A signature was required, but no signature exists
```

After the refused upgrade, the node stayed on its signed deployment, nothing was staged, and
RKE2 never noticed anything happened. Images signed with the wrong key, unsigned RPMs, and
repodata signed with a key the client does not hold all fail too. The
[troubleshooting page](troubleshooting.md#a-signature-was-required-but-no-signature-exists)
lists each error.

Then the signed images went through the full install, upgrade and rollback again, this time
with signatures checked at every hop. Promotion is still a plain tag copy. The signature is
bound to the digest, so `rocky-edge:10` verifies the moment it points at a signed build.

!!! warning "What is still missing: TLS"
    Signatures protect the content end to end over plain HTTP, but tag-to-digest resolution,
    the unsigned EPEL metadata, and the first fetch of the public key all trust the network.
    Terminating TLS at Artifact Keeper's Caddy front door and distributing its CA is the next
    step. It touches every registry address in the pipeline, which is why it is kept separate.
    [Next steps](next-steps.md#turn-on-tls) lists what changes.

**Next:** [Results](results.md).
