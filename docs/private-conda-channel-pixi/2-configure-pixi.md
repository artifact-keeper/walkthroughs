# Step 2: Configure pixi for registry-only use

The goal is that a developer or a CI job can name `conda-forge` in a manifest the way they always
have, and the request goes to the registry. That is done with mirrors in pixi's system config, not
by editing projects.

## The client image

Every pixi step runs in `localhost/ak-conda/pixi-client:0.81.0`
([`client/Containerfile`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/client/Containerfile)).
It starts from `ghcr.io/prefix-dev/pixi:0.81.0`, pulled **through the registry's** `oci-ghcr`
proxy, adds the internal CA to the system trust store, and installs two config files. It contains
no credentials; the token arrives at run time as a mounted file named by `RATTLER_AUTH_FILE`.

`/etc/pixi/config.toml`:

```toml
tls-root-certs = "system"
default-channels = ["https://ak.internal/conda/conda-virtual"]

[mirrors]
"https://conda.anaconda.org/conda-forge" = ["https://ak.internal/conda/conda-forge"]
"https://prefix.dev/conda-forge"         = ["https://ak.internal/conda/conda-forge"]

[pypi-config]
index-url = "https://ak.internal/pypi/pypi-remote/simple"
```

`tls-root-certs` accepts `system` or `webpki`, not a file path, which is why the CA goes into the
system store. `pypi-config.index-url` only affects `pixi init`; an existing project sets
`[pypi-options] index-url` in its own manifest.

`/etc/rattler/config.toml` is the same file minus `pypi-config`, because rattler-build reads the
shared subset and warns about keys it does not know. rattler-build 0.76 reads these files by
default, so the mirrors apply to package builds too.

## Credentials

Two ways, both producing an `Authorization: Bearer` header on every request and nothing in any
file a developer commits:

- Interactive: `pixi auth login ak.internal --token "$(cat consumer.token)"`. The credential is
  stored in the system keyring or `~/.rattler/credentials.json`, keyed by the bare hostname.
- CI: `RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json`, a JSON map `{"ak.internal": {"BearerToken": "..."}}`,
  mounted from a secret. Runners can inject environment variables and files but rarely let you
  write a keyring, so this is the form the walkthrough uses everywhere.

The same credential store serves the PyPI index, so a mixed project needs one token.

## The consumer project

[`project/pixi.toml`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/project/pixi.toml):

```toml
[workspace]
channels = ["https://ak.internal/conda/conda-virtual", "https://ak.internal/conda/conda-internal"]
channel-priority = "strict"
platforms = ["linux-64"]
exclude-newer = "14d"

[exclude-newer]
"acme-*" = "0d"

[pypi-options]
index-url = "https://ak.internal/pypi/pypi-remote/simple"

[dependencies]
python = "3.12.*"
acme-core   = { version = ">=1.0,<2", channel = "https://ak.internal/conda/conda-internal" }
acme-report = { version = ">=1.0,<2", channel = "https://ak.internal/conda/conda-internal" }
acme-fastmath = { version = ">=1.0,<2", channel = "https://ak.internal/conda/conda-internal" }

[pypi-dependencies]
humanize = "*"
```

Why each line is there:

- **One virtual channel.** Consumers get `conda-virtual` and nothing else to think about. The
  registry decides what is in it ([Step 5](5-resolve-through-one-channel.md)).
- **Internal names are pinned to the internal channel.** `channel = ...` on a dependency means the
  solver may only take that package from that channel. pixi requires the pinned channel to be
  listed in `channels`, which is the only reason `conda-internal` appears there as well; the pin,
  not the order, does the work. This is belt and braces on top of the registry's own name
  ownership rule, and it costs one line per internal package.
- **`channel-priority = "strict"`** is pixi's default. Never set it to `disabled` in a project
  that mixes internal and public channels.
- **`exclude-newer = "14d"`** is a dependency cooldown: nothing published to conda-forge in the
  last two weeks is eligible, which is the window in which most malicious uploads are caught. The
  `acme-*` override turns the cooldown off for our own packages, since we want them the moment
  they are promoted.

The lockfile this produces records conda-forge packages at their canonical
`https://conda.anaconda.org/conda-forge/...` URLs, even though every download went to the
registry. That is the mirrors feature doing its job: the lock is portable to any mirror, and a
second registry serving the same packages will satisfy it unchanged. The three internal packages
record `https://ak.internal/conda/conda-internal/...`, and the PyPI wheel records the registry's
index. No token appears anywhere; the gate for that greps the manifest and the lock for every
minted token, for `user:pass@`, and for `/t/<token>/`.

Next: [Step 3, build, publish and attest](3-build-and-publish.md).
