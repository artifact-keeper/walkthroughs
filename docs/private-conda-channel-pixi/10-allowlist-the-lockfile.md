# Step 10: Allowlist what comes from conda-forge

<!-- DRAFT: commands and outputs are exact (gate run 2026-10-08, backend
localhost/ak-backend:allowlist-1.11); the prose is plain on purpose and will be rewritten. -->

Up to here `conda-virtual` offers everything on conda-forge: 790,754 linux-64 records. The name
rule from [Step 5](5-resolve-through-one-channel.md) stops conda-forge from shadowing an internal
name, but any other public package is one `pixi add` away. This step closes that: the virtual
channel gets an allowlist, and the allowlist is the project's own `pixi.lock`.

What the allowlist does (Artifact Keeper
[#4576](https://github.com/artifact-keeper/artifact-keeper/issues/4576)):

- It is set on the **virtual** repository and applies to the records its **remote** members
  contribute. Hosted members (`conda-internal`) are never filtered; they are curated by promotion
  ([Step 4](4-promote-with-gates.md)).
- An entry is a package name (exact or a glob), an optional conda version spec and optional
  subdirs. A bare version (`3.12.14`) means exactly that version. Builds are not part of the
  match: every build of an admitted version is admitted.
- It is enforced in two places that agree: the index (`repodata.json`, `.zst`, `.bz2` and
  `channeldata.json`) and the download path. A package that is not admitted is not in the
  repodata, so the solver reports it as not found, and its file is 404 through the virtual
  channel, also when it is already in the proxy's cache.
- `enabled` is explicit. Enabled with no entries admits nothing from conda-forge; disabled keeps
  the entries and serves the full merge.

## Set it from the lock

[`allowlist/from-lock.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/allowlist/from-lock.sh)
reads the `- conda:` entries of `project/pixi.lock`, takes name and version from each file name
and the subdir from its URL, and `PUT`s one entry per package with `enabled: true`. The request
replaces the list, so running it again after `pixi lock` is all it takes to follow the lock.

```console
$ make allowlist
allowlist/from-lock.sh
allowlist: 43 entries from project/pixi.lock (linux-64 31, noarch 12)
allowlist: PUT /api/v1/repositories/conda-virtual/allowlist -> HTTP 200 {"enabled":true,"entry_count":43}
allowlist/show.sh
conda-virtual: enabled=true entries=43
  _openmp_mutex      4.5          linux-64
  acme-core          1.0.0        noarch
  acme-fastmath      1.0.0        linux-64
  acme-report        1.0.0        noarch
  bzip2              1.0.8        linux-64
  ...
```

The request body, one entry per locked conda package:

```json
{
  "enabled": true,
  "entries": [
    {"name": "_openmp_mutex", "version": "4.5", "subdirs": ["linux-64"]},
    {"name": "numpy", "version": "2.5.3", "subdirs": ["linux-64"]},
    {"name": "python-dateutil", "version": "2.9.0.post0", "subdirs": ["noarch"]},
    ...
  ]
}
```

The three `acme-*` entries are in the list because they are in the lock; they make no difference,
because hosted records are not filtered.

## What the channel serves now

```text
noarch/repodata.json: x-ak-allowlist-dropped: 382366
noarch: 22 records (17 from the remote covering 10 name/version pairs, 5 hosted); lock: 12 files
linux-64/repodata.json: x-ak-allowlist-dropped: 790523
linux-64: 231 records (230 from the remote covering 30 name/version pairs, 1 hosted); lock: 31 files
channeldata.json: x-ak-allowlist-dropped: 34585
channeldata.json: 43 names; colorama listed: 0
```

linux-64 goes from 790,754 records to 231. The remote part is exactly the lock's 30 linux-64
name/version pairs; it is 230 records rather than 30 because each version has several builds
(`numpy 2.5.3` for every Python, for example). The `X-AK-Allowlist-Dropped` response header says
how many records the list left out. `.json`, `.zst` and `.bz2` decode to the same document.

## A package outside the lock

`colorama` is on conda-forge and not in the lock:

```text
GET /conda/conda-forge/noarch/colorama-0.4.6-pyhd8ed1ab_1.conda  200   (the remote itself is not filtered)
GET /conda/conda-virtual/noarch/colorama-0.4.6-pyhd8ed1ab_1.conda  404  {"code":"NOT_FOUND","message":"Artifact not found in any member repository"}
```

The 404 is the same one the virtual channel gives for a package no member has. Asking pixi for
it, in a copy of the project:

```console
$ pixi add --no-install colorama      # allowlist on
Error:   × failed to solve requirements of environment 'default' for platform 'linux-
  │ 64'
  ├─▶   × failed to solve the environment
  │   
  ╰─▶ Cannot solve the request because of: No candidates were found for
      colorama *.
```

Not found, at solve time. Not a resolve that succeeds and then fails on download, which is what
a download-only block (the remote repository's upstream filter) would give.

## The project still installs

```console
$ NETWORK=build-isolated project/pixi-run.sh install --locked      # cold cache
The default environment has been installed.
```

```text
conda-virtual requests during install: 41 (40 package downloads 200, 0 other than 200/304)
```

40 conda-forge packages through the allowlisted channel, the three `acme-*` packages from
`conda-internal`, `humanize` from `pypi-remote`.

## Turn it off

```console
$ make allowlist-off
allowlist/off.sh
allowlist: PUT /api/v1/repositories/conda-virtual/allowlist -> HTTP 200 {"enabled":false,"entry_count":43}
```

```text
allowlist off: colorama download HTTP 200; linux-64 records 790754; channeldata 34628 names, colorama listed: true
$ pixi add --no-install colorama      # allowlist off
Added colorama >=0.4.6,<0.5
```

`off.sh` keeps the entries and sets `enabled: false`; `off.sh --delete` removes the list. Every
change is in the audit log as `REPOSITORY_ALLOWLIST_CHANGED` with the previous and current
`enabled` and `entry_count`.

## What to notice

- The allowlist binds `conda-virtual`, not `conda-forge`. The consumer token in this walkthrough
  can still read the `conda-forge` proxy directly (the client config mirrors `conda-forge` to it),
  so a developer who adds `-c conda-forge` gets past the list. To make the list binding, consumers
  get no read access to the remote repository; only the virtual channel.
- Builds are not matched. A lock pins one build; the allowlist admits every build of that version.
- The gate ([`gates/g14-allowlist.sh`](https://github.com/artifact-keeper/walkthroughs/blob/main/private-conda-channel-pixi/gates/g14-allowlist.sh))
  turns the allowlist off when it finishes, because the demo runs with it off.

Now the [results](results.md).
