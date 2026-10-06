# Findings: iteration 2, sign everything, verify everywhere

!!! note "Lab notes"
    Lab notes from 2026-10-06, kept as recorded. Tags here (`10.2-1`, `10.2-2`) predate signing;
    the current equivalents are `10.2-3`/`10.2-4`. See the [Findings overview](findings.md)
    for the summary.

Run on 2026-10-06 on the same Fedora 44 workstation as iteration 1, now with **`/dev/kvm`
enabled** (`crw-rw-rw- root /dev/kvm`; `deploy/lib.sh` picked `-accel kvm -cpu host`
automatically). Rootless podman 5.8.7, skopeo 1.22.3, cosign 3.1.3, GnuPG 2.4.9,
QEMU 10.2.2, Artifact Keeper (AK) v1.10.2 on `localhost:30080`. No sudo anywhere.
The spec is the "Iteration 2" section of `docs/PLAN.md`; keys and the trust model are in
`signing/README.md`.

## Summary

| Gate | Result |
|---|---|
| 6. Unsigned image fails `podman build FROM`, kickstart and `bootc upgrade`, each with the signature error | **Pass**, all three, plus `skopeo copy`, a wrong-key signature, an unsigned RPM and a wrong repodata key (errors verbatim below) |
| 7. Signed images pass all three | **Pass** (`podman build` FROM the signed base, kickstart of `rocky-edge:10` = 10.2-3, `bootc upgrade` to 10.2-4) |
| 8. `rpm -K` and dnf `gpgcheck=1` / `repo_gpgcheck=1` | **Pass**. `rpm -K`: `digests signatures OK` for 1.0-3 and 1.0-4; the edge image builds with gpgcheck=1 on all 8 repos and repo_gpgcheck=1 on 6 of them |
| 9. Full install, boot, verify, upgrade, rollback with KVM on signed images | **Pass**. Install 65 s, power-on to node Ready 86 s, upgrade 27 s, see the timing table |

Not done: the TLS stretch goal (Caddy internal CA on :30443). See the last section.

Final references (`skopeo inspect --no-creds`; all signed ones verify with
`cosign verify --key signing/keys/pub/edge-cosign.pub`):

| Ref | Digest | Signed |
|---|---|---|
| `oci-bootc/rocky-bootc-base:10` (= `:10-20261006`) | `sha256:c85c88d42d2595b216e09a9fc2b1e3086b4ca7038745bfd2efc79bb10326298a` | yes |
| `oci-bootc/rocky-bootc-base:unsigned` | `sha256:435de1550ea652c84a36dc08d50fb1231a29d51d49b2463ee229e83dc13aa3ef` | **no** (negative test) |
| `oci-bootc/rocky-edge:10.2-3` | `sha256:d4f3ec69bbd3d44be1160d8ef0818714a480cca5ad7347a69dda23101f58d84f` | yes |
| `oci-bootc/rocky-edge:10.2-4` (= `:10` at the end) | `sha256:c98876108f864a75e7a7f958fda049d72673652e8eae5849c63dac893bb38f16` | yes |
| `oci-bootc/rocky-edge:unsigned-test` | `sha256:ad0578dbfe628c2c66edef1f5b99fe730dd3feb89d5985abbc980efb4d970484` | **no** (10.2-4 rebuilt with label `edge.test=unsigned`) |

The iteration-1 tags `rocky-edge:10.2-1` / `10.2-2` and RPMs `1.0-1` / `1.0-2` are still in
AK, unsigned. With the new policies nothing can install them any more (shown below).

RPM signing key: `D6E39478ABE514BFB354E36A765CD686C1F8F57D` (Edge Site Signing
\<edge@example.invalid>). AK repodata key for `rpm-edge-site`:
`56F1A82FBCA31EF9E96E2EC1B0BDCA2543BDB898`. cosign public key sha256
`61c588fc414d10fc56d7c46c0e29e14d7303f0c68ffa25c0a23134a51fddd174`.

## 1. Keys (`signing/gen-keys.sh`)

- cosign key pair with `COSIGN_PASSWORD=""` (`cosign generate-key-pair --output-key-prefix cosign`),
  RPM key with `gpg --batch --gen-key` in a throwaway `GNUPGHOME` (`%no-protection`,
  RSA 4096, sign-only, no expiry). Both in `signing/keys/` (mode 700, gitignored); public halves in
  `signing/keys/pub/`. Re-running keeps existing keys.
- Vendor keys: `https://rpm.rancher.io/public.key` (Rancher (CI) `C8CFF216455126E9B9C918BE925EA29AE257814A`),
  `https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-10` (`7D8D15CBFC4E62688591FB2633D98517E37ED158`).
- **Rocky 10's key is already in the base image** (`/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10`, owned by
  `rocky-gpg-keys-10.2-1.2.el10`), so repo files use `file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10`.
  The file holds **two keys**, and the second is an OpenPGP **v6** key. GnuPG 2.4.9 cannot read it:
  `gpg: packet(6) with unknown version 6` / `gpg: read_block: read error: Invalid packet`.
  rpm (Sequoia backend) and dnf import both (`gpg-pubkey-6fedfc85-682ae1a9` and
  `gpg-pubkey-2ebba43f-6a7b0932`, both "Release Engineering (Rocky Linux 10)"). For gpg-based checks,
  `signing/verify.sh` uses only the first (v4) armored block.

## 2. Keys in the registry: `raw-edge-keys` (generic repo)

`backend/src/models/repository.rs` has a `Generic` format (`"generic"`). `registry/bootstrap.sh`
now creates `raw-edge-keys|generic|local` with `is_public: true`, and `signing/publish-keys.sh`
uploads the four public keys:

```
PUT  /api/v1/repositories/raw-edge-keys/artifacts/<file>      (CI token, Content-Type set explicitly) -> 201
GET  /api/v1/repositories/raw-edge-keys/download/<file>       (anonymous) -> 200, identical bytes
```

Verified anonymously with `curl` from the host, from a podman container
(`host.containers.internal`) and from the installer (`10.0.2.2`, kickstart `%pre`).

AK behaviour worth knowing:

- **The native generic route is not reachable through the stock Caddyfile.** The backend mounts
  `GET /general/<repo>/<path>` (`handlers/general.rs`), but `docker/Caddyfile` has no
  `/general/*` line, so the request falls through to the Next.js web UI and returns its HTML 404
  page. The REST download route under `/api/*` works, so that is what we use.
- Generic paths are **write-once**: a second `PUT` to the same path returns **409**
  (unless the repo has `versioning_enabled`). Replacing a key means `DELETE` + `PUT`, and
  `DELETE` needs the `delete:artifacts` scope: our CI token (`read:artifacts`,`write:artifacts`)
  gets **403**, so `publish-keys.sh` logs in as admin only for the delete.
- Without an explicit `Content-Type`, `curl --data-binary` uploads were stored and later served as
  `application/x-www-form-urlencoded`; AK echoes whatever the uploader sent.

## 3. RPM signing and repodata signing

### Our RPM

`rpms/build.sh` installs `rpm-build rpm-sign gnupg2` in the `rockylinux:10` builder (through the AK
proxies, now with gpgcheck/repo_gpgcheck on), mounts `signing/keys/gnupg` **read-only**, copies it
into a throwaway `GNUPGHOME` inside the container (gpg needs a writable homedir for its agent socket),
and after `rpmbuild` runs:

```
rpmsign --addsign --define "_gpg_name D6E39478ABE514BFB354E36A765CD686C1F8F57D" <rpm>
rpm --import /keys/RPM-GPG-KEY-edge; rpm -K <rpm>
/out/edge-site-config-1.0-3.el10.noarch.rpm: digests signatures OK
/out/edge-site-config-1.0-4.el10.noarch.rpm: digests signatures OK
  edge-site-config-1.0-3.el10.noarch signature: RSA/SHA256, Tue 06 Oct 2026 09:02:49 AM CDT, Key ID 765cd686c1f8f57d
```

Build + sign of both releases: 7 s. `%{SIGPGP:pgpsig}` prints `(none)` on EL10 even for a signed
package; the header tag that carries it is `RSAHEADER` (`%{RSAHEADER:pgpsig}`). 1.0-3 = 1.0-1 content
(baseline MOTD, `edge-site/config-release=3`), 1.0-4 = day-2 (`config-release=4`). Uploaded with
`rpms/upload.sh` (201; 1.0-1/1.0-2 answered 409, already there).

### AK repodata signing (`rpm-edge-site`)

Exactly what was sent (admin JWT; repo id from `GET /api/v1/repositories/rpm-edge-site`) and what came back:

```
GET  /api/v1/signing/keys                      -> {"keys":[],"total":0}
GET  /api/v1/signing/repositories/80be1ec3-1d07-49bf-a21d-aa8a0b4e6bb3/config
  -> {"repository_id":"80be1ec3-...","signing_key_id":null,"sign_metadata":false,"sign_packages":false,"require_signatures":false,"key":null}

POST /api/v1/signing/keys
  {"name":"rpm-edge-site repodata","key_type":"gpg","algorithm":"rsa4096",
   "repository_id":"80be1ec3-1d07-49bf-a21d-aa8a0b4e6bb3",
   "uid_name":"Artifact Keeper rpm-edge-site","uid_email":"rpm-edge-site@example.invalid"}
  -> HTTP 200 {"id":"c3ee7ad3-d5e9-4649-bec2-9c176c532c7e","repository_id":"80be1ec3-...",
     "name":"rpm-edge-site repodata","key_type":"gpg",
     "fingerprint":"56f1a82fbca31ef9e96e2ec1b0bdca2543bdb898","key_id":"b0bdca2543bdb898",
     "public_key_pem":"-----BEGIN PGP PUBLIC KEY BLOCK-----...","algorithm":"rsa4096",
     "uid_name":"Artifact Keeper rpm-edge-site","uid_email":"rpm-edge-site@example.invalid",
     "expires_at":null,"is_active":true,"created_at":"2026-10-06T14:00:41.722084407Z","last_used_at":null}

POST /api/v1/signing/repositories/80be1ec3-1d07-49bf-a21d-aa8a0b4e6bb3/config
  {"signing_key_id":"c3ee7ad3-d5e9-4649-bec2-9c176c532c7e","sign_metadata":true}
  -> HTTP 200 {"id":"d2f0a12c-61d3-473d-b666-34db58c8f8f4","repository_id":"80be1ec3-...",
     "signing_key_id":"c3ee7ad3-...","sign_metadata":true,"sign_packages":false,
     "require_signatures":false,"created_at":"2026-10-06T14:00:49.120224Z","updated_at":"..."}
```

`bootstrap.sh` now does the same idempotently (`sign_repo_metadata rpm-edge-site`; re-runs report
`repodata signing already enabled on rpm-edge-site (key 56f1a82f...)`). The private key stays inside
AK (encrypted with a key derived from `JWT_SECRET`, per `SigningService::new`). Immediately afterwards:

```
repomd.xml      200 application/xml           1744 bytes
repomd.xml.asc  200 application/pgp-signature  841 bytes
repomd.xml.key  200 application/pgp-keys      1668 bytes
gpg --import repomd.xml.key; gpg --verify repomd.xml.asc repomd.xml
gpg: Good signature from "Artifact Keeper rpm-edge-site <rpm-edge-site@example.invalid>" [unknown]
gpg: Signature expires Tue 13 Oct 2026 09:00:49 AM CDT
```

Notes: the key type must be `gpg` for rpm/debian repos (the handler rejects `rsa`/`ed25519` for
them). The signature carries a **7-day expiry** (`SIGNATURE_EXPIRY_SECONDS`, default 7 d, issue #1327)
and AK re-signs on demand from a cache, so a mirror that copies `repomd.xml.asc` once would go stale.
`sign_packages` (AK signing RPMs itself) and `require_signatures` were left off: we sign in the build.

### Do the proxies pass through upstream `repomd.xml.asc`? Yes, where upstream has one

`handlers/rpm.rs` proxies `repodata/repomd.xml.asc` for remote repos (#1447). Compared byte for byte
against upstream (`signing/verify.sh` repeats the gpg check every run):

| Proxy | upstream `.asc` | AK `.asc` | repomd.xml identical | `.asc` verifies with |
|---|---|---|---|---|
| `rpm-rocky10-baseos` / `-appstream` / `-extras` | 200 | 200, identical | yes | Rocky 10 key (`FC226859C0860BF0DDB95B085B106C736FEDFC85`) |
| `rpm-rke2-common`, `rpm-rke2-1.36` | 200 | 200, identical | yes | Rancher key |
| `rpm-epel10` | 404 | 404 | yes | n/a: EPEL does not sign repomd |
| `rpm-k3s` | 404 | 404 | yes | n/a |

So `repo_gpgcheck=1` for Rocky, RKE2 and `rpm-edge-site`; `repo_gpgcheck=0` (packages still
`gpgcheck=1`) for EPEL and k3s.

## 4. Repo files

`registry/out/edge.repo.in` (generated by `bootstrap.sh`, rendered with `sed s/@HOST@/<host>/g`;
note: **every** occurrence now, not just `baseurl=` lines, because `gpgkey=` carries the host too):

| Repo | gpgcheck | repo_gpgcheck | gpgkey |
|---|---|---|---|
| `rpm-rocky10-*` | 1 | 1 | `file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10` (in-image) |
| `rpm-epel10` | 1 | 0 | `http://@HOST@:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-EPEL-10` |
| `rpm-k3s` | 1 | 0 | `.../raw-edge-keys/download/RPM-GPG-KEY-Rancher` |
| `rpm-rke2-common`, `rpm-rke2-1.36` | 1 | 1 | `.../raw-edge-keys/download/RPM-GPG-KEY-Rancher` |
| `rpm-edge-site` | 1 | 1 | `.../raw-edge-keys/download/RPM-GPG-KEY-edge` and `http://@HOST@:30080/rpm/rpm-edge-site/repodata/repomd.xml.key` |

The "only Artifact Keeper" gate (Containerfile `RUN` and `image/build.sh`) now also checks `gpgkey=`
URLs (must be `:30080/` or `file:///etc/pki/rpm-gpg/`) and fails on any `gpgcheck=0`.
`base/build.sh` gets the same three Rocky sections (gpgcheck/repo_gpgcheck on).

Edge image build log (dnf `-y` imports keys unattended; first for repomd, then for packages):

```
Importing GPG key 0x6FEDFC85:  From /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
Importing GPG key 0x2EBBA43F:  From /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
Importing GPG key 0xE257814A:  From http://host.containers.internal:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-Rancher
Importing GPG key 0xC1F8F57D:  From http://host.containers.internal:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-edge
Importing GPG key 0x43BDB898:  From http://host.containers.internal:30080/rpm/rpm-edge-site/repodata/repomd.xml.key
...
Key imported successfully
```

Image rpmdb afterwards: `gpg-pubkey-6fedfc85`, `-2ebba43f` (Rocky), `-e257814a` (Rancher),
`-c1f8f57d` (edge), `-43bdb898` (AK rpm-edge-site).

Gate 8 negatives (in the built image / a Rocky container, against AK):

```
$ dnf downgrade edge-site-config-1.0-1.el10          # iteration-1 RPM, unsigned
Package edge-site-config-1.0-1.el10.noarch.rpm is not signed
Error: GPG check FAILED
$ dnf upgrade edge-site-config-1.0-4.el10            # signed
Upgraded: edge-site-config-1.0-4.el10.noarch
$ dnf makecache   # rpm-edge-site with repo_gpgcheck=1 but only the Rancher key as gpgkey
Error: Failed to download metadata for repo 'rpm-edge-site': repomd.xml GPG signature verification error: Signing key not found
```

## 5. Image signing, and how AK stores cosign signatures

### cosign 3 needs the legacy format for containers-image

cosign 3.1.3 by default writes the new Sigstore **bundle** format and attaches it with the
**OCI referrers API**, and it wants Rekor/TUF. AK handled that fine:

```
GET /v2/oci-bootc/sigtest/referrers/sha256:634a8f35...   (bearer token from /v2/token)
{"manifests":[{"artifactType":"application/vnd.dev.sigstore.bundle.v0.3+json",
  "annotations":{"dev.sigstore.bundle.content":"dsse-envelope",
  "dev.sigstore.bundle.predicateType":"https://sigstore.dev/cosign/sign/v1",...},
  "digest":"sha256:8cda2508...","mediaType":"application/vnd.oci.image.manifest.v1+json","size":887}],
 "mediaType":"application/vnd.oci.image.index.v1+json","schemaVersion":2}
```

but **containers-image (podman, skopeo, bootc, Anaconda) cannot see it**: an image signed only
that way fails the policy with `Source image rejected: A signature was required, but no signature exists`
while `cosign verify` succeeds. podman 5.8 / skopeo 1.22 only read "sigstore attachments" (the
`sha256-<digest>.sig` tag). So we sign with (hidden, deprecated) flags:

```
cosign sign --yes --key signing/keys/cosign.key --allow-http-registry --allow-insecure-registry \
  --tlog-upload=false --new-bundle-format=false --use-signing-config=false \
  localhost:30080/oci-bootc/rocky-edge@sha256:<digest>
Flag --new-bundle-format has been deprecated, this will be the only supported format in future versions
Pushing signature to: localhost:30080/oci-bootc/rocky-edge
```

That warning is the real risk for this design: a future cosign may drop the legacy format before
containers-image learns the bundle format. Pin cosign or use `podman push --sign-by-sigstore-private-key`,
which writes the same attachment format natively.

Also: **cosign does not use podman's auth file** (`$XDG_RUNTIME_DIR/containers/auth.json`); the
first signing attempt failed with
`POST http://localhost:30080/v2/oci-bootc/rocky-bootc-base/blobs/uploads/: UNAUTHORIZED: authentication required`.
`signing/lib.sh` logs in with `podman login --authfile signing/keys/docker/config.json` and exports
`DOCKER_CONFIG=signing/keys/docker`.

### What AK stores

- A tag `sha256-<digest>.sig` in the same repository (`skopeo list-tags`:
  `["10","10.2-1","10.2-2","10.2-3","10.2-4","sha256-c9887610...f16.sig","sha256-d4f3ec69...84f.sig","unsigned-test"]`).
  It is an OCI image manifest with one layer `application/vnd.dev.cosign.simplesigning.v1+json`
  (252 bytes) annotated `dev.cosignproject.cosign/signature`. The AK artifacts API lists it as
  `v2/rocky-edge/manifests/sha256-<digest>.sig`, 485 bytes, like any other manifest. Nothing in the
  AK UI or API treats it as a signature (AK does not sign or verify OCI images itself).
- The referrers endpoint returns an empty index for legacy-signed images (correct: no `subject`).
- `cosign tree`:
  ```
  📦 Supply Chain Security Related artifacts for an image: localhost:30080/oci-bootc/rocky-edge:10
  └── 🔐 Signatures for an image tag: localhost:30080/oci-bootc/rocky-edge:sha256-d4f3ec69...84f.sig
     └── 🍒 sha256:ba2db9fef22704b0328ee0831015bb24c949a3b59d8dd8dcd910ee7afb71fe3f
  ```
- `cosign verify --key signing/keys/pub/edge-cosign.pub --allow-http-registry --insecure-ignore-tlog
  localhost:30080/oci-bootc/rocky-edge:10`:
  ```
  The following checks were performed on each of these signatures:
    - The cosign claims were validated
    - The signatures were verified against the specified public key
  [{"critical":{"identity":{"docker-reference":"localhost:30080/oci-bootc/rocky-edge"},
    "image":{"docker-manifest-digest":"sha256:d4f3ec69..."},"type":"cosign container image signature"},"optional":null}]
  ```

### Promotion stays a tag copy

`make promote` / `vm-upgrade.sh` still do `skopeo copy docker://...:10.2-4 docker://...:10`. The digest
is unchanged, so `cosign verify ...:10` passes right after the copy, and the existing `.sig` was not
duplicated (still one layer). The copy itself now reads the source through the build-host policy, so
promoting an unsigned image fails on the build host already; the day-2 negative test has to use
`skopeo copy --insecure-policy` to get the unsigned image onto `:10` at all.

### Gotcha: "unsigned" copies that are still signed

`skopeo copy containers-storage:localhost/rocky-bootc-base:10 docker://.../rocky-bootc-base:unsigned`
produced **the same digest** (`c85c88d4...`) as the signed `:10`, so the "unsigned" tag was covered by
the signature. Signatures belong to digests, not tags. The negative-test base was pushed with
`--format v2s2` (new manifest digest `435de155...`, same layers); `rocky-edge:unsigned-test` differs by a label.

### Gotcha: pushing an image that was pulled through the policy

After `image/build.sh` pulled the signed base, the local image carried its sigstore signatures, and
`base/build.sh`'s next `podman push` failed:
`Error: Copying this image would require changing layer representation, which we cannot do: "Would invalidate signatures"`.
Pushes now use `podman push --remove-signatures` (the digest is re-signed after the push anyway).

### Build-host verification (`image/setup-host.sh`)

User-level files only:

- `~/.config/containers/policy.json`: a copy of `/etc/containers/policy.json` (this host's default is
  already `reject` with explicit accepts per transport) plus
  `transports.docker["localhost:30080/oci-bootc"] = [{"type":"sigstoreSigned","keyPath":"<repo>/signing/keys/pub/edge-cosign.pub","signedIdentity":{"type":"matchRepository"}}]`.
  A user-level `policy.json` **replaces** the system one, so starting from a copy keeps the
  system's rules (here: ublue-os and toolbx sigstore keys); on a host without one the base is
  `default: insecureAcceptAnything`.
- `~/.config/containers/registries.d/ak-oci-bootc.yaml`: `docker: localhost:30080/oci-bootc: use-sigstore-attachments: true`.
  A user-level `registries.d` also **replaces** `/etc/containers/registries.d`, so the system's yaml
  files are symlinked next to it.
- **`signedIdentity` must not be the default.** cosign writes a *tag-less* identity
  (`"docker-reference":"localhost:30080/oci-bootc/rocky-edge"`). containers-image's default
  `matchRepoDigestOrExact` (and `remapIdentity`, which builds on it) rejects name-only identities:
  `Source image rejected: Signature for identity "localhost:30080/oci-bootc/sigtest" is not accepted`,
  for tag and digest references alike. `matchRepository` and `exactRepository` accept them.

Gate 6/7 on the build host (`image/build.sh`'s `podman pull` of the base is now the check):

```
$ podman build --pull=always -f Containerfile.unsigned .     # FROM localhost:30080/oci-bootc/rocky-bootc-base:unsigned
STEP 1/2: FROM localhost:30080/oci-bootc/rocky-bootc-base:unsigned
Trying to pull localhost:30080/oci-bootc/rocky-bootc-base:unsigned...
Error: creating build container: unable to copy from source docker://localhost:30080/oci-bootc/rocky-bootc-base:unsigned: Source image rejected: A signature was required, but no signature exists
(exit 125)
$ skopeo copy docker://localhost:30080/oci-bootc/rocky-bootc-base:unsigned dir:x
FATA[0000] Source image rejected: A signature was required, but no signature exists
$ podman pull localhost:30080/oci-bootc/rocky-bootc-base:unsigned
Error: unable to copy from source docker://localhost:30080/oci-bootc/rocky-bootc-base:unsigned: Source image rejected: A signature was required, but no signature exists
$ skopeo copy docker://localhost:30080/oci-bootc/sigtest:wrongkey dir:x        # signed with a different cosign key
FATA[0000] Source image rejected: cryptographic signature verification failed: invalid signature when validating ASN.1 encoded signature
$ podman build --pull=always -f Containerfile.signed .       # FROM .../rocky-bootc-base:10
Successfully tagged localhost/postest:latest
```

`skopeo inspect` of the unsigned image **succeeds**: inspect does not evaluate `policy.json`
(only copies/pulls do), so it is not a useful check.

## 6. Node-side verification (in the image)

`image/rootfs/etc/containers/policy.json` **replaces** the base's (from `containers-common-5.8-2.el10`,
`default: insecureAcceptAnything` plus two Red Hat sigstore scopes):

- `default: reject`; `containers-storage`, `oci`, `oci-archive`, `dir`, `docker-archive`: accept (local only).
- `docker` `10.0.2.2:30080/oci-bootc/rocky-edge` (and `.../rocky-bootc-base`): `sigstoreSigned`,
  `keyPath: /etc/pki/containers/edge-cosign.pub`,
  `signedIdentity: {"type":"exactRepository","dockerRepository":"localhost:30080/oci-bootc/rocky-edge"}`.
  `exactRepository`, because the signature names the signer's view of the registry (`localhost:30080`)
  and the node pulls as `10.0.2.2:30080`; `remapIdentity` would map the host but inherits the
  tag-less-identity rejection above. With one DNS name for the registry everywhere this would be
  a single `matchRepository` scope.
- `docker` `10.0.2.2:30080/oci-bootc`: `reject` (anything else in that repo); the Red Hat scopes are kept.

`registries.d/ak-oci-bootc.yaml` (`use-sigstore-attachments` for `10.0.2.2:30080/oci-bootc`) and
`/etc/pki/containers/edge-cosign.pub` (copied in by `image/build.sh` from `signing/keys/pub`) complete it.
The insecure-registry drop-in from the RPM stays (plain HTTP). RKE2's containerd does not use
`policy.json`, so workload pulls are unaffected (they are not signed by us anyway).
`bootc container lint --fatal-warnings`: 13 passed, 1 skipped, for 10.2-3, 10.2-4, unsigned-test.

## 7. Kickstart

`deploy/ks.cfg.in`: `--no-signature-verification` removed. `%pre --erroronfail` writes the installer's
`policy.json` (default `reject`, the `exactRepository` rule above), `registries.d/ak-oci-bootc.yaml`,
and `curl`s the key from `http://10.0.2.2:30080/api/v1/repositories/raw-edge-keys/download/edge-cosign.pub`.
New placeholders `@IMAGE_REPO@`, `@SIGNED_REPO@`, `@KEY_URL@` (rendered by `render-ks.sh`).
`%post` writes the three files into the installed system **only if the image lacks them** (it never
does, `/root/ks-post.log` on the node says `kept image-provided ...` three times). Writing a
*different* copy would turn them into locally modified `/etc` files that a later image (say, with a
rotated key) could no longer update through the ostree 3-way merge.

A `reject` default did **not** break Anaconda (nothing else in the install pulls images).

**Gate 6, kickstart** (`IMAGE=rocky-edge:unsigned-test make vm-install`), serial console verbatim:

```
The following error occurred while installing the payload. This is a fatal errorand installation will be aborted.

The command 'ostree container image deploy --sysroot=/mnt/sysimage
--image=10.0.2.2:30080/oci-bootc/rocky-edge:unsigned-test --transport=registry'
exited with the code 1:
error: Performing deployment: Preparing import: Fetching manifest: failed to
invoke method OpenImage: A signature was required, but no signature exists


Press ENTER to exit:
```

Anaconda then waits for ENTER forever. `vm-install.sh` now scans the serial log every 5 s for
`Source image rejected|A signature was required|Signature for identity|signature verification|...`,
prints the context, kills QEMU and exits 1:
`[09:32:41] install: SIGNATURE VERIFICATION FAILED (+40s)` ...
`ERROR: install aborted: the image failed signature verification` (46 s wall clock, versus the
2400 s timeout it would otherwise have hit).

**What actually enforces it (measured).** Two extra installs of `unsigned-test` with modified templates:

| Kickstart | Installer policy | Result |
|---|---|---|
| ours (no flag) | ours (`reject` + sigstoreSigned) | **refused** (above) |
| ours **plus** `--no-signature-verification` | ours | **refused**, same error, +40 s |
| no flag | installer stock policy (`install.img` `/etc/containers/policy.json`: `default: insecureAcceptAnything`) | **installed** the unsigned image (66 s) |

And the installed node's origin is `container-image-reference=ostree-unverified-registry:10.0.2.2:30080/oci-bootc/rocky-edge:10`
even without the flag. So on Rocky 10.2 (ostree 2025.7, bootc 1.16.4), `--no-signature-verification`
only selects ostree-ext's "unverified" image reference mode, which *still* runs the pull through
`containers-policy.json`; removing the flag alone protects nothing. The policy is the control, for
Anaconda and for `bootc upgrade` alike. (Nothing refused a default `insecureAcceptAnything` policy
either; the "ostree-image-signed" mode that would insist on a real policy is not what Anaconda selects.)

**Gate 7, kickstart**: `make vm-install` of `rocky-edge:10` (= 10.2-3, signed): `Installation complete`
in 65 s; `vm-boot` shows the policy on the node:

```
=== image signature policy (bootc upgrade) ===
container-image-reference=ostree-unverified-registry:10.0.2.2:30080/oci-bootc/rocky-edge:10
default: [{'type': 'reject'}]
10.0.2.2:30080/oci-bootc/rocky-edge [{'type': 'sigstoreSigned', 'keyPath': '/etc/pki/containers/edge-cosign.pub', 'signedIdentity': {'type': 'exactRepository', 'dockerRepository': 'localhost:30080/oci-bootc/rocky-edge'}}]
...
61c588fc414d10fc56d7c46c0e29e14d7303f0c68ffa25c0a23134a51fddd174  /etc/pki/containers/edge-cosign.pub
```

## 8. Full gate with KVM (gate 9) and the day-2 negative test

`make vm-clean vm-install vm-boot vm-verify vm-upgrade-unsigned vm-upgrade vm-verify vm-rollback vm-verify`,
then one more `vm-rollback` so the node ends on the image `:10` points at.

**Day-2 negative** (`make vm-upgrade-unsigned`, new script `deploy/vm-upgrade-unsigned.sh`):

```
[09:21:50] booted: 10.0.2.2:30080/oci-bootc/rocky-edge:10 @ sha256:d4f3ec69...84f
[09:21:51] promote (unsigned!): localhost:30080/oci-bootc/rocky-edge:unsigned-test -> localhost:30080/oci-bootc/rocky-edge:10
[09:21:52] tag now: sha256:ad0578dbfe628c2c66edef1f5b99fe730dd3feb89d5985abbc980efb4d970484

=== bootc upgrade (must fail) ===
error: Upgrading: Preparing import: Fetching manifest: failed to invoke method OpenImage: A signature was required, but no signature exists
[09:21:52] upgrade-unsigned: bootc upgrade refused after 0s
node: edge-node-01 Ready
[09:21:53] upgrade-unsigned: OK (refused; still booted sha256:d4f3ec69...84f, nothing staged, rke2-server active)
[09:21:54] restored localhost:30080/oci-bootc/rocky-edge:10 -> sha256:d4f3ec69...84f
```

**Day-2 positive** (`make vm-upgrade`, `PROMOTE_FROM=rocky-edge:10.2-4`):
`layers already present: 73; layers needed: 3 (7.8 MB)`, `Deploying...done (2 seconds)`, booted 10.2-4
(`c98876108f...`), rollback 10.2-3, MOTD `edge-site-config 1.0-4.el10: day-2 update via bootc upgrade (release 4)`,
`nginx-demo ... edge-site/config-release=4`. `vm-rollback` -> 10.2-3, MOTD `1.0-3.el10: initial site configuration`,
`config-release=3`; second `vm-rollback` -> back on 10.2-4. `vm-verify` passed after each.

### Timings: KVM (this run) vs TCG (iteration 1, run 3)

| Stage | KVM | TCG | Notes |
|---|---|---|---|
| `vm-install` total | **65 s** | 601 s | KVM run serves stage2 locally (below) |
|  - QEMU start to "Starting installer" | 25 s | 315 s | |
|  - to "Installing the software" | +15 s | +60 s | %pre now also fetches the key |
|  - `ostreecontainer` pull + deploy (74 layers, 463 MB) | 15 s | 195 s | |
|  - post-install to QEMU exit | 10 s | 30 s | |
| `vm-install`, stage2 from dl.rockylinux.org | 276 s to "Starting installer" | (315 s) | 750 MB `install.img` at about 3 MB/s = 250 s; the network, not the CPU |
| Negative install, until `vm-install` aborts | 40 s (46 s wall) | n/a | |
| `vm-boot`: power-on to ssh | **25 s** | 52 s | |
| `vm-boot`: ssh to node Ready | **61 s** | 272 s | |
| `vm-verify`: nginx-demo Running | already Running when checked (< 21 s after Ready) | 76 s after Ready | |
| `vm-upgrade-unsigned`: `bootc upgrade` refused | < 1 s (target 4 s) | n/a | |
| `vm-upgrade`: promote copy | 1 s | 1 s | |
| `vm-upgrade`: `bootc upgrade` pull + stage | **6 s** | 69 s | 3 layers, 7.8 MB |
| `vm-upgrade`: reboot to ssh | **20 s** | 148 s | |
| after upgrade: workload re-settled (`vm-verify`) | 81 s | 30-105 s | mostly the RKE2 restart and Deployment rollout |
| `vm-rollback`: reboot to ssh | 101 s (both times) | 148 s | slower than the upgrade reboot; not investigated (no stop-job timeouts in the serial log) |
| after rollback: workload re-settled | 122 s | 30-105 s | |
| Power-on to working cluster | **about 3 min** (65 + 25 + 61 + ~20 s) | about 17 min | |

Build-side (no VM): `rpms/build.sh` (build + sign 2 RPMs) 7 s; edge image 27 s (layer 1 rebuilt
because the repo files changed), 8 s for release 4, 1 s for `unsigned-test`; push 1-2 s and sign 1 s
per image.

**Install media**: under KVM, 250 of the 276 s before "Starting installer" were dracut downloading
`install.img` from the mirror. `deploy/fetch-media.sh` now also caches `images/install.img`
(sha256-checked against `.treeinfo`, like the kernel and initrd) and `serve-ks.sh` serves it with the
kickstart (`inst.stage2=http://10.0.2.2:8000/os/`), which is what a PXE install server does anyway.
`STAGE2=mirror` restores the old behaviour.

## 9. AK behaviours: confirmed vs not

Confirmed:

- Signing API (`/api/v1/signing/keys`, `/signing/repositories/{id}/config`) creates a server-side GPG key and
  signs `rpm-edge-site` repodata; `repomd.xml.asc`/`.key` served anonymously; signature verifies with gpg and dnf;
  7-day signature expiry.
- RPM remote repos pass upstream `repomd.xml.asc` through byte-identical (Rocky, Rancher), and repomd.xml too.
- OCI registry stores cosign legacy `.sig` tags and new-format bundles via the referrers API
  (`GET /v2/<repo>/<name>/referrers/<digest>` returns a proper OCI index with `artifactType`).
- Generic repo `raw-edge-keys` works for anonymous key distribution via `/api/v1/repositories/<key>/download/<path>`.
- Tag copies keep the digest, so promotion needs no re-signing.

Not confirmed / gaps:

- The native generic route `/general/<key>/<path>` is unreachable through the stock Caddyfile (falls to the web UI 404).
- AK itself neither signs nor verifies OCI images, and does not surface `.sig` tags as signatures in its artifacts
  API; they look like any other manifest. Promotion rules with `require_signature` (`handlers/promotion_rules.rs`) were not tried.
- The "Signing" page in the web UI was not used (the key was created through the API, as required); not checked
  whether it shows the API-created key.
- `sign_packages` (AK signing RPMs on upload) not tried; we sign in the build.
- OCI `DELETE` (skopeo delete, admin) removed the scratch test tags from the registry, but the manifests stayed in
  `GET /api/v1/repositories/oci-bootc/artifacts` until deleted through the REST API as well.

## 10. Gotchas {#10-gotchas-short-list-for-the-blog}

1. cosign 3 defaults (bundle format + referrers + Rekor) are invisible to podman/skopeo/bootc/Anaconda; sign with
   `--new-bundle-format=false --use-signing-config=false --tlog-upload=false` (deprecated flags) or with podman's
   built-in sigstore signing.
2. cosign identities are tag-less: use `signedIdentity` `matchRepository`/`exactRepository`, never the default.
3. The signer's registry name is in the signature; a node that reaches the registry under another name needs
   `exactRepository` (or one DNS name everywhere).
4. `--no-signature-verification` is not the switch: `policy.json` is enforced with and without it, and without a
   policy nothing is enforced either way.
5. Signatures follow digests: a "new unsigned tag" of an identical image is signed; a tag copy (promotion) needs no re-signing.
6. User-level `~/.config/containers/policy.json` and `registries.d/` replace the system ones wholesale.
7. `skopeo inspect` ignores `policy.json`; test with `skopeo copy` or `podman pull`.
8. A pulled-and-verified image carries its signatures in local storage; pushing it elsewhere needs `--remove-signatures`.
9. Rocky 10's RPM key file includes a v6 OpenPGP key that GnuPG 2.4 cannot parse (rpm/dnf can).
10. `%{SIGPGP}` is empty on EL10 RPMs; use `%{RSAHEADER:pgpsig}`.
11. AK: generic repos are write-once per path, deletes need `delete:artifacts`, set `Content-Type` on upload,
    and use `/api/v1/repositories/<key>/download/` behind the stock Caddy.
12. EPEL 10 and Rancher's k3s el9 tree do not sign repomd.xml, so `repo_gpgcheck=1` cannot be universal.
13. With KVM, the slowest part of an install is downloading the 750 MB stage2; serve it locally.

## 11. Stretch goal not done: TLS

Not attempted. It is more than a Caddy change: the registry name (`10.0.2.2:30443`) would change in every
image reference, the kickstart, both repo files, RKE2's `registries.yaml` (an RPM content change, so new
`edge-site-config` releases), the policies' scopes and the signed identity, and Caddy's internal CA would have
to issue a certificate with an IP SAN for `10.0.2.2` to clients that connect without SNI, through the
rootless port forward. The signature chain does not depend on it: everything above verifies content end to
end over plain HTTP. What TLS would add is confidentiality and integrity for the unsigned parts (tag to
digest resolution, EPEL/k3s repo metadata, the key download in `%pre`, which today trusts the network on
first use).
