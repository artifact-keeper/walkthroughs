# Next steps

The pipeline in this walkthrough takes shortcuts that make sense on one machine: three names
for one registry, plain HTTP, a VM instead of hardware, keys without passphrases, and an
internet uplink. From here, the hardening is deployment choices rather than new machinery. The
[Adapting](adapting.md) page lists every file each change touches; this
page summarizes them.

## Turn on TLS

Signatures already protect content end to end. TLS adds confidentiality and protects the
unsigned parts: tag-to-digest resolution, the EPEL and k3s metadata, and the key download in
the kickstart `%pre`. Terminate TLS at Artifact Keeper's Caddy front door and distribute its CA
(an internal CA is fine). Then:

- switch every `baseurl=`, `gpgkey=`, mirror endpoint and key URL to `https://`;
- drop `--tls-verify=false`, `--allow-http-registry` and `--allow-insecure-registry` from
  the build, push and signing scripts;
- remove the insecure-registry drop-ins from the kickstart and from `edge-site-config` (as a
  new release, since uploads are write-once);
- add the CA certificate to the installer's trust store in `%pre` and to
  `/etc/pki/ca-trust/source/anchors/` in the image, unless it is a public CA.

## Use one DNS name

The proof of concept reaches the registry as `localhost:30080` on the host,
`host.containers.internal:30080` in builds and `10.0.2.2:30080` on the node. Give it one name
that resolves everywhere, for example `registry.example.internal`. The two `.repo` views
collapse into one file, and cosign records the same name the nodes pull from, so every
`policy.json` can use `signedIdentity: matchRepository` and drop the `exactRepository`
mapping from [Step 6](6-sign-and-verify.md#the-policy-that-enforces-it).

## Pin by digest

Install nodes by digest and let them track the tag, or go further and promote by digest. A
floating tag is convenient for a demo, but a digest says exactly what a node was installed
from, and an air-gapped site should stop installing by tag altogether.

## Boot real hardware over PXE

The harness already boots the installer the way a PXE server would: no ISO, just the Rocky
pxeboot `vmlinuz` and `initrd.img`, a stage2 and a kickstart over HTTP. On hardware, a DHCP
server points UEFI clients at iPXE, and an iPXE script does what QEMU's `-kernel`, `-initrd`
and `-append` do in the harness. Serve the installer kernel, initrd and stage2 from the
registry too, so the install media come from the same source of truth. Render the kickstart
per site or per node, and name the target disk with `ignoredisk --only-use=`, because
`clearpart --all` wipes every disk the installer sees.

## Block egress

RKE2's generated containerd configuration keeps `registry-1.docker.io` as the fallback behind
the Artifact Keeper mirror, so a mirror miss quietly goes to the internet if it can. Block
egress from the nodes at the network. For a disconnected site, pre-warm the proxy repositories
(every RPM, the builder image and every RKE2 system image) or convert them to hosted
repositories filled by a transfer process.

## Protect the keys

Protect the cosign key with a passphrase or keep it in a KMS or HSM, and do the same for the
RPM key. Pin the cosign key's fingerprint in the kickstart instead of trusting the first
download, and rotate keys by shipping the new public key in an image signed with the old one.
The [adapting page](adapting.md#production-keys) has the rotation sequence.

## What's next for Artifact Keeper

Running Artifact Keeper this hard produced a handful of improvements, which is part of why
these projects exist. The compose and documentation fixes are already in, so the quickstart
matches what this walkthrough describes. The
[1.11.0 release](https://github.com/artifact-keeper/artifact-keeper/issues/4468) adds
signature-aware views for OCI repositories, so cosign signatures show up on the image they
belong to instead of as separate tags, corrects the storage accounting for shared layers, and
adds server-side image signing, which turns the cosign step in
[Step 6](6-sign-and-verify.md) into a registry setting. The full list of what came out of
this project is on the
[Artifact Keeper notes](artifact-keeper-notes.md) page.

Questions, or a deployment you would like to see walked through? Open an issue on
[artifact-keeper/walkthroughs](https://github.com/artifact-keeper/walkthroughs/issues).
