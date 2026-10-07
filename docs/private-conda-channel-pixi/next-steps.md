# Next steps

## Adapting this to your organization

- **Keyless signing from CI.** If your CI runs on GitHub Actions and public Sigstore is
  acceptable, drop the key: `rattler-build` and `pixi upload` can produce CEP-27 attestations with
  the workflow's OIDC identity, and the registry's `CONDA_ATTESTATION_ISSUERS` and
  `CONDA_ATTESTATION_IDENTITIES` pin which workflows may publish. The key-based path in this
  walkthrough is for shops that cannot.
- **A private Sigstore.** Between the two: run your own Fulcio and Rekor and point the trust
  policy at them. The verification code path is the same as keyless.
- **One DNS name and a real CA.** `ak.internal` with Caddy's internal CA stands in for your
  internal DNS and PKI. Swap the certificate and the hostname; nothing else changes, because every
  client already trusts a CA you distribute through the `trust` repository.
- **Tokens.** Mint consumer tokens with a repository selector covering the virtual channel's
  members until a virtual-scoped token can read through (requested). Rotate the CI token with the
  staging repository's token API; it never needs more than staging.
- **More channels.** Add `bioconda` or an internal `-dev` channel as members of the virtual
  channel at the right priority; the ownership rule applies to every hosted member.
- **Air gap.** Replace the conda-forge proxy with a replicated hosted copy on the inside, keep
  everything else. Builds already assume no internet.
- **Real CI runners.** Attach runners to the registry network and drop the podman-in-podman from
  `image/build.sh`; it exists only because rootless `podman build` cannot join a named network.

## Watch for in the clients

- pixi exposing rattler's install-time attestation verification: then
  `verify-attestations.sh` becomes a config setting.
- pixi using `indexed_timestamp` for `exclude-newer`, which closes the backdating gap.
- Syft emitting PURLs for conda packages, which would let Grype deduplicate its conda findings.

## In Artifact Keeper

- Proxy downloads recorded in the download audit (needs a schema change).
- Shards served through the conda-forge proxy and for virtual channels.
- Scan-on-proxy for conda, so public packages are scanned before they are served, not only
  after they are installed.
- A repository-level "N of M packages attested" count, which needs an aggregate API.

The 1.11.0 release notes list everything that came out of this walkthrough; the
[lab notes](findings.md) are the record behind them.
