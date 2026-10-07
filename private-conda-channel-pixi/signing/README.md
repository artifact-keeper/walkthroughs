# signing

- `gen-keys.sh`: cosign key pairs in `keys/` (gitignored): the CI publish key and `keys/wrong/`,
  an untrusted key for the negative tests. Passwords in `cosign.password`.
- `publish-keys.sh`: puts `cosign.pub` into the registry's public `trust` repository as
  `conda-ci-cosign.pub`.

The same key signs CEP-27 package attestations (`packages/attest.sh`) and the application image
(`image/push.sh`). Signing uses no public transparency log (`--use-signing-config=false
--tlog-upload=false`); verification uses `--insecure-ignore-tlog` with the key.
