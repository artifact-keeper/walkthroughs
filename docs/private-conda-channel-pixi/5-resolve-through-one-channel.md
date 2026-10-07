# Step 5: Resolve through one channel

`conda-virtual` is what developers and builds use. It merges `conda-internal` (priority 1) and
the `conda-forge` proxy (priority 2) into one channel, and three registry rules make that safe
rather than convenient.

**Hosted members own their package names.** If `acme-core` exists in `conda-internal`, no version
of `acme-core` from the conda-forge member appears in the virtual channel, in any subdir. This is
the registry-side defense against dependency confusion: an attacker who publishes `acme-core 99.0`
to a public channel gets nothing, because the name is taken. Client-side strict priority alone does
not do this; we checked. With strict priority and the internal channel first, a name that is
*missing* from the internal channel silently resolves from conda-forge, and a name that is present
can still be outbid by a higher public version in some configurations. The registry rule closes
both. The pins in `pixi.toml` from [Step 2](2-configure-pixi.md) are the second layer.

**Members are fetched compressed and capped, hosted first.** conda-forge's linux-64 index is
about 300 MB uncompressed and 58 MB as zstd. The virtual channel fetches each remote member's
repodata as `.zst` (falling back to `.bz2`, then `.json`), under a byte cap (128 MiB fetched,
1 GiB decoded by default), and merges hosted members before remote ones. The result for
`conda-virtual/linux-64/repodata.json.zst` is 790,178 records in 74 MB, served in about 4 seconds.

**A broken member fails loudly.** If a member cannot be fetched or parsed, the virtual channel
answers 502 and names the member, instead of returning 200 with that member silently missing. A
silently empty conda-forge is exactly the condition under which a name squatter wins, so a visible
failure is the safe behavior. A per-repository setting (`virtual_metadata_partial`) allows a
degraded response for teams who prefer availability, marked with a warning header and no caching.

## Formats

pixi asks for repodata in a fixed order and falls back on 404: first the CEP-16 sharded index
(`repodata_shards.msgpack.zst`, one small shard per package name, which makes solves on large
channels many times faster), then `HEAD` requests for `.zst` and `.bz2`, then the best available.
The hosted channels serve shards, and pixi uses them:

```text
GET /conda/conda-internal/noarch/repodata_shards.msgpack.zst          200  content-type: application/x-msgpack
GET /conda/conda-internal/noarch/shards/<sha256>.msgpack.zst          200
```

The conda-forge proxy does not yet serve shards for its upstream; pixi falls back to `.zst`
there with no client configuration. The `.json`, `.zst` and `.bz2` variants agree with each other,
and both `.conda` and `.tar.bz2` packages index and install.

A small thing the gates check because it broke us once: the shard files are already zstd, so the
registry must not also set `Content-Encoding: zstd`, or HTTP clients strip one layer and rattler
fails with "Unknown frame descriptor". 1.11.0 serves them as plain resources.

## Freshness

The proxy's metadata TTL is per repository (`conda-forge` uses 300 seconds here; the freshness gate
sets 45 to prove the point). A package published upstream appeared in the proxy 30 to 35 seconds
after publishing with the 45-second TTL. A mirror that is months behind is a real failure mode in
this ecosystem; a TTL you set, and can read back from the API, is how you avoid it.

## Cooldowns and the server's clock

Every record the registry indexes carries `indexed_timestamp`, set by the server when the package
was indexed (CEP-47). It exists because `exclude-newer` cooldowns are only as trustworthy as the
timestamp they filter on, and a package's own `timestamp` is set by whoever built it. pixi 0.81
still filters on the build timestamp, so a backdated package gets past the cooldown today; rattler
already uses `indexed_timestamp`, and pixi will follow. The walkthrough shows the field and names
the limitation rather than pretending the cooldown is airtight.

## The proof

The consumer project locks and installs on the isolated network with a cold cache:

```console
$ project/pixi-run.sh install --locked      # on build-isolated, PIXI_CACHE_DIR empty
 ...
$ project/pixi-run.sh run --locked start
┏━━━━━━━━┳━━━━━━━━┓
┃ column ┃   mean ┃
┡━━━━━━━━╇━━━━━━━━┩
│ sales  │ 119.33 │
└────────┴────────┘
```

44 packages, every one downloaded from `ak.internal`; the network has no DNS for
`conda.anaconda.org` or `pypi.org` and no route to the internet. The lockfile keeps the canonical
conda-forge URLs. The cooldown is visible in it: `openssl 3.6.4` was locked although 3.6.5 existed,
because 3.6.5 was less than 14 days old. [Step 8](8-sbom-and-blast-radius.md) shows Grype flagging
exactly that, which is the case pixi's own docs describe: exempt the fix with
`[exclude-newer] openssl = "0d"` when you want it early.

Next: [Step 6, build the container on an isolated network](6-build-the-container.md).
