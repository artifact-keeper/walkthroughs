# Plan: a private conda channel for pixi, with supply-chain controls

Status: design for review, 2026-10-06. Implementation starts against this plan; gates below define done.
Companion to the Rocky Linux image mode walkthrough. Code lands in `private-conda-channel-pixi/` of this repo.

## Who this is for

Platform and security teams at large organizations that run Python and data science on conda,
already front everything with an artifact manager, and have to answer auditors: where did every
package come from, who published it, was it verified before it was installed, and can we prove the
build used nothing else. The requirements below are drawn from what such teams have asked for in
public (registry and client issue trackers, published internal tooling), not from any one company.

## Requirements the walkthrough must demonstrate

| # | Requirement | Where it is demonstrated |
|---|---|---|
| R1 | Credentials never appear in channel URLs, manifests or lockfiles; clients send an `Authorization` header from a credential store keyed by host | pixi auth store, `RATTLER_AUTH_FILE` in CI, lock inspection |
| R2 | Bearer tokens work for reads and publishing; per-repository, read-only tokens for consumers | Artifact Keeper repo tokens |
| R3 | A proxy of conda-forge, a hosted internal channel, and one virtual channel with predictable priority | three repositories plus `conda-virtual` |
| R4 | Internal package names cannot be shadowed by the public proxy (dependency confusion) | name-ownership guard in the virtual channel, negative test |
| R5 | Correct repodata formats: `.conda` and `.tar.bz2`, `repodata.json`, `.zst`, `.bz2`, CEP-16 shards, fast fallbacks | pixi against every format; shard index consumed by rattler |
| R6 | Proxy metadata freshness with an admin-set TTL and no silent staleness; failed members fail loudly | proxy TTL, virtual member failure test |
| R7 | Immutable artifacts (no overwrite), promotion by repointing, withdrawal with a notice, audit of pulls and pushes | 409 on re-upload, staging to internal promotion, CEP-6 notice, download records |
| R8 | CEP-27 publish attestations stored and served per CEP-50, verified by the registry on upload and by the consumer before linking | attestation upload, `.sigs` sidecars, `attestations_sha256` in repodata, verification gate in the container build |
| R9 | Enterprise trust policy for attestations: configurable identity and issuer, key-based bundles for on-premises CI, not only public GitHub OIDC | registry trust-policy settings, key-based signing in the demo CI |
| R10 | Server-set `indexed_timestamp` so `exclude-newer` cooldowns are trustworthy | repodata field, pixi `exclude-newer` |
| R11 | SBOM, PURLs, vulnerability and license scanning for what is served and what is installed; blast-radius lookup from a PURL to environments | hosted scanning, environment SBOM from `pixi.lock`, reverse lookup |
| R12 | Registry-only builds: the build network has no internet, the lockfile is portable across mirrors, offline install works from the lock | internal podman network, mirrors config, `pixi install --frozen --offline` |
| R13 | Everything runs in containers with a bare hostname and TLS from an internal CA | `ak.internal` on the compose network, Caddy internal CA, `tls-root-certs` |
| R14 | Only approved public packages reach consumers: the virtual channel admits an allowlist of conda-forge packages, enforced in the index (the solver reports "not found") and on download; the project's `pixi.lock` is the allowlist | allowlist on `conda-virtual` from `pixi.lock` (#4576), negative test with a package outside the lock |

## Environment

- **Registry**: Artifact Keeper built from `main` plus the fixes below (this is 1.11.0 work), run as its own
  compose project `ak-conda` on an internal podman network. Caddy answers on `https://ak.internal` (port 443
  on the network, not on the host). The Caddy internal CA is exported and trusted by every client container.
  Reason: pixi looks credentials up by bare hostname and drops the port, and large organizations do not
  send credentials over HTTP.
- **Clients**: every pixi and rattler-build step runs in a container on the same network. A second
  network, `build-isolated`, has `internal: true` (no route to the internet) and is used for the
  registry-only proofs. The only container with internet access is Artifact Keeper itself.
- **Repositories**:
  - `conda-forge` (format `conda`, remote, upstream `https://conda.anaconda.org/conda-forge`)
  - `conda-internal` (hosted, visibility `internal`): released internal packages
  - `conda-staging` (hosted): where CI publishes; promotion to `conda-internal` is gated
  - `conda-virtual` (virtual: `conda-internal` priority 1, `conda-forge` priority 2): the one channel
    consumers use
  - `pypi-remote` (remote PyPI proxy) so mixed conda and PyPI projects also resolve through the registry
  - `oci-apps` (hosted OCI) for the built application images
- **Internal packages**, built with `rattler-build` from `recipe.yaml`, in a container:
  - `acme-core` (noarch python): a small library
  - `acme-fastmath` (linux-64, compiled): exercises a real subdir
  - `acme-report` (noarch): depends on `acme-core` plus `pandas` and `rich` from conda-forge
  All names carry the reserved prefix `acme-`.
- **Consumer project**: `pixi.toml` with `channels = ["https://ak.internal/conda/conda-virtual"]`,
  `channel-priority = "strict"`, `exclude-newer = "14d"`, internal dependencies pinned with
  `channel = "https://ak.internal/conda/conda-internal"`, one PyPI dependency, and a `pixi.lock`.
- **Container build**: the pixi-on-UBI-micro multi-stage pattern. Builder: `ghcr.io/prefix-dev/pixi`
  pinned by digest (through the registry's proxy), `/etc/pixi/config.toml` with mirrors pointing at
  `ak.internal`, credentials via a podman secret as `RATTLER_AUTH_FILE`, `pixi install --locked`,
  then an attestation verification gate over every package in `pixi.lock`. Runtime: UBI micro with
  the environment and a `pixi shell-hook` entrypoint. Image signed with cosign and pushed to `oci-apps`.
- **Scanning**: Syft with the conda cataloger plus Grype on the built environment; the registry's
  hosted scan results; `POST /api/v1/sbom/environment?filename=pixi.lock` and the environment
  register with PURL reverse lookup.

## Decisions

1. **One virtual channel, and make it correct.** Two channels in pixi (internal, then proxy) works
   today, but it leaves dependency confusion to client discipline. Large organizations want one channel
   URL that is safe by construction. So the virtual channel is the product story, and the fixes below
   make it hold: hosted-owns-the-name guard, compressed and capped member fetch, loud member failure,
   hosted-first merge.
2. **Key-based attestations for the demo, keyless for GitHub.** Public Sigstore with a GitHub Actions
   issuer is what works on `main` today. Regulated shops often cannot use public Sigstore; they sign
   with their own keys or a private Sigstore. The demo CI signs CEP-27 predicates with a cosign key
   (`cosign attest-blob` producing a Sigstore bundle, no public transparency log) and the registry is
   configured with that public key as its trust policy. The GitHub Actions keyless path stays supported
   and is documented.
3. **Attestations are served, not only stored.** CEP-50 sidecars (`<file>.sigs`, `.sigs.<sha256>`) and
   `attestations_sha256` in repodata, readable anonymously wherever the package is. Consumers verify
   before linking; the container build does this with `cosign verify-blob --bundle` over every locked
   package, and the docs point at rattler's built-in verification as pixi adopts it.
4. **Promotion is the gate.** CI publishes to `conda-staging`. Promotion to `conda-internal` requires:
   a verified attestation, a passed vulnerability scan, and a license on the allow list. Consumers
   never see staging. Rollback is withdrawing with a CEP-6 notice, not overwriting.
5. **Shards are in scope for the hosted channel, stretch for the proxy.** Hosted shards must be
   consumable by rattler (fix the encoding). Shards through the proxy (#4177) are attempted if time
   allows; otherwise `disable-sharded` is set for the proxy URL in the client config and the gap is
   documented.
6. **Everything the client needs to trust is served by the registry**: the CA certificate, the
   attestation verification key, and the SBOMs, each from a generic repository `trust`.

## Artifact Keeper work for 1.11.0

Found by the audit of `main` (5e351fc) and the client research; each becomes an issue (or links an
existing one) and a fix branch. Fixes are prepared locally, built into the demo image, and listed for
Brandon's approval before any PR is opened.

| # | Item | Existing issue | Gate |
|---|---|---|---|
| F1 | Virtual channel: hosted members own their package names; remote versions of a name present in a hosted member are excluded from the merge (same guard other formats have) | new | G4 |
| F2 | Virtual channel: fetch members compressed with a byte cap and streaming; hosted-first merge order | #4180 | G3, G5 |
| F3 | Virtual channel: a member that fails to fetch or parse fails the request loudly instead of being dropped | #4192 | G6 |
| F4 | CEP-16 shard index: encode hashes as raw bytes per the spec; add a rattler-based test | #4173 (partial) | G5 |
| F5 | CEP-50: serve `.sigs` sidecars and `attestations_sha256`; anonymous `GET .../attestation` on readable repos | new (#4033 epic) | G8 |
| F6 | Attestation trust policy: configurable OIDC issuers and identities, and key-based Sigstore bundles with a configured public key | new (#4033 epic) | G8, G9 |
| F7 | Attestation state feeds policy and promotion: `min_attestation_state` and `require_signature` recognize a verified CEP-27 attestation | new | G7 |
| F8 | Upload validates the subdir against `index.json`; POST without `X-Conda-Subdir` uses the package's own subdir | new | G2 |
| F9 | Promotion copies artifact metadata (depends, md5, attestation) | new, verify first | G7 |
| F10 | `indexed_timestamp` set by the server on every repodata record (CEP-47) | new | G10 |
| F11 | Accept rattler's `/t/<token>/` URL layout (`/t/{token}/conda/{repo}/...`) | new | G1 |
| F12 | Site docs: a conda and pixi page with the real upload API, `conda` versus `conda_native`, auth, mirrors | site, new | docs |
| F20 | Virtual channel package allowlist (name and conda version spec, optional subdirs), applied to remote members' records in repodata (json, zst, bz2) and channeldata and on download; hosted members not filtered | [#4576](https://github.com/artifact-keeper/artifact-keeper/issues/4576) | G14 |

Out of scope for this walkthrough, noted in the docs: scan-on-proxy for conda (#4097), quotas (#4422),
JLAP patches (#4175), and the full scale epic (#4172).

## Gates

| # | Gate | Proof |
|---|---|---|
| G1 | Auth: `pixi auth login ak.internal --token` and `RATTLER_AUTH_FILE` both work; `pixi.lock` and `pixi.toml` contain no credentials; a token in the URL is accepted by the registry but the docs show the header form | lock grep, registry access log |
| G2 | Publish: `rattler-build upload artifactory` PUTs three packages to `conda-staging` with a Bearer token; re-upload returns 409; a `linux-64` package uploaded without a subdir header lands in `linux-64` | HTTP transcripts |
| G3 | Resolve: a `pixi install --locked` of the consumer project through `conda-virtual` succeeds on a network with no internet; the lock records conda-forge URLs, downloads hit the proxy | pixi output, registry download records |
| G4 | Dependency confusion: `acme-core 99.0` published to the remote member's upstream is not offered by `conda-virtual`; the solve keeps the internal version | repodata diff, solve output |
| G5 | Formats: pixi consumes zst, bz2, json and the hosted shard index without falling back; proxy shards pass through or `disable-sharded` is documented | request log |
| G6 | Freshness and failure: a new conda-forge package appears within the TTL; a broken member makes the virtual channel fail loudly | logs |
| G7 | Promotion: an un-attested or vulnerable package in `conda-staging` is refused promotion; the attested, clean package promotes with its metadata intact and resolves from `conda-internal` | promotion API responses, `depends` check |
| G8 | Attestations: CEP-50 sidecars are served; the container build's verification gate passes for signed packages and fails the build for a tampered or unsigned one | build logs |
| G9 | Trust policy: an attestation signed by the wrong key or a disallowed identity is rejected on upload | 400 responses |
| G10 | Cooldown: repodata carries server-set `indexed_timestamp`; `exclude-newer` excludes a package indexed minutes ago | solve output |
| G11 | SBOM and blast radius: SBOM from `pixi.lock` via the registry; Syft plus Grype on the built image; a PURL lookup returns the environments that contain it | API responses, scan output |
| G12 | Offline: `pixi install --frozen --offline` from a pre-filled cache succeeds with the network removed; a package with a flipped byte fails the sha256 check | output |
| G13 | Image: the application image builds from the registry only, is signed, and runs | podman output, cosign verify |
| G14 | Allowlist: with the allowlist set from `pixi.lock`, `conda-virtual` repodata (json, zst, bz2) lists exactly the lock's conda-forge packages plus every hosted record; channeldata lists no other name; a conda-forge package outside the lock is 404 and `pixi add` reports it not found; `pixi install --locked` still succeeds; turning the allowlist off restores the full merge | repodata and channeldata diff against the lock, HTTP codes, pixi output |


## UI track: what the screenshots must show

Each screen below is a screenshot in the walkthrough. Where the web UI (`artifact-keeper-web`)
cannot show it today, that is a UI work item for 1.11.0, prepared the same way as the backend fixes.

| # | Screen | Shows | Likely UI work |
|---|---|---|---|
| U1 | Repositories list filtered to conda | the four channels with type (remote, hosted, staging, virtual) and visibility | none expected |
| U2 | `conda-virtual` detail | members in priority order, with the name-ownership rule stated | member priority display; a note that hosted members own their names |
| U3 | `conda-internal` artifact list | packages grouped by name with subdir, version, build, size | subdir column if missing |
| U4 | Package detail for `acme-report` | depends, license, sha256, uploader, upload time, and the **attestation**: verified, identity, issuer or key, verification time, link to the sidecar | attestation panel (new) |
| U5 | Scan results for a conda package | Grype/Trivy findings per component, PURLs | none expected |
| U6 | Promotion from `conda-staging` to `conda-internal` | the gate decision: attestation verified, scan passed, license allowed; and the refusal for the un-attested package with the reason | gate-result display per rule (likely new) |
| U7 | Withdrawn package | the CEP-6 notice text and the `removed` state | notice display if missing |
| U8 | Environments | a registered `pixi.lock`, its SBOM, and the PURL reverse lookup result (blast radius) | environment list and lookup UI if missing |
| U9 | Download audit for a package | who pulled what and when | none expected |
| U10 | Trust settings | the attestation trust policy (issuers, identities, key) and the repodata signing key | settings page for the policy (new) |

Screenshots are taken headlessly against the demo stack, light theme, cropped to the panel, and
stored under `docs/private-conda-channel-pixi/images/`.

## Walkthrough outline

1. Why one channel: the enterprise problem statement.
2. Stand up the registry on a private network with TLS and a bare hostname.
3. Create the channels: proxy, hosted, staging, virtual; tokens for CI and for consumers.
4. Configure pixi for registry-only: auth store, mirrors, strict priority, cooldowns, pinned internal names.
5. Build and publish internal packages with rattler-build; attest them.
6. Promote with gates: scan, license, attestation.
7. Resolve and lock through the virtual channel; prove no other source was reached.
8. Build the application container on an isolated network; verify attestations before linking; sign the image.
9. SBOM, scanning and blast radius.
10. The negative tests: confusion, overwrite, tampering, wrong key, offline.
11. Allowlist what comes from conda-forge: the lockfile is the allowlist.
12. What changed in Artifact Keeper for this (1.11.0) and what is next.
