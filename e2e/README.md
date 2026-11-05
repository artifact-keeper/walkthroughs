# Nightly end-to-end runs

Every night, `ak_e2e.py` runs every walkthrough in this repository from a fresh checkout,
against two Artifact Keeper versions, and reports what changed:

| Version | Images | A failure here means |
|---|---|---|
| `release` | the latest GitHub release: backend from `artifact-keeper/artifact-keeper`, web from `artifact-keeper/artifact-keeper-web` | the published walkthrough no longer works as written |
| `dev` | `:dev` of both | an early warning: the next release may break the walkthrough |

It runs on one host (today `grace`) as a systemd user service with a timer. Walkthroughs must
follow the [e2e contract](../CONTRIBUTING.md#the-e2e-contract).

## What one night does

1. Takes a lock, creates `~/ak-e2e/runs/<date>/`, and resolves both versions to image digests
   (anonymous ghcr.io and GitHub API reads).
2. Clones this repository and fetches `main`, every open PR labelled `e2e`, and the branches in
   `E2E_EXTRA_REFS`. From `main` it tests every walkthrough; from another ref, only the
   walkthroughs that are new or whose non-Markdown files differ from `main`.
3. For each walkthrough, for each version, in sequence, in its own fresh worktree:
   - skips with `BLOCKED(...)` if the walkthrough is not in `walkthroughs.toml`, its stack
     conflicts with something on the host, a host requirement or disk space is missing, the
     release is older than its `min_ak`, or its images cannot be pulled;
   - pulls the backend and web images by digest and passes them as `AK_BACKEND_IMAGE` and
     `AK_WEB_IMAGE` (`repo:tag@sha256:...`);
   - runs `make clean`, `make all`, `make gates`, `make clean`, each with a hard timeout;
     the last `make clean` runs even after a failure;
   - records the digests of the images the running stack actually uses, parses the gate
     verdicts, copies `out/gates/` into the logs, and lists anything left after `make clean`
     (it removes what this run created and keeps the rest).
4. Writes `summary.json` and `report.txt`, compares with the previous night, greps its own
   files for every secret (and redacts them), and reports.

## Verdicts

Per walkthrough and version: `PASS`, `FAIL` or `BLOCKED(reason)`.

- `FAIL`: a check printed `FAIL`, `make all` or `make gates` failed or timed out, or the final
  `make clean` failed.
- `BLOCKED(reason)`: the run says nothing about the walkthrough. Reasons: `conflict` (same
  container, volume or network names, ports or subnets already in use on the host), `disk`,
  `network`, `registry-pull`, `host` (a required tool or `/dev/kvm`), `preflight`,
  `min-version`, `unregistered`, `contract` (no `all`, `gates` or `clean` target), `patch`,
  `runner` (a bug in this runner). A failed step whose log ends in an infrastructure error
  (no space left, rate limit, DNS, port in use) is `BLOCKED`, not `FAIL`.
- Checks are listed one by one in `summary.json`. A check that a walkthrough reports as
  `BLOCKED(...)` (a missing secret, an unlanded Artifact Keeper fix) does not fail the run.

## Output

```
~/ak-e2e/runs/<date>/
  summary.json        versions and digests, sources, per run: steps (exit, seconds, log),
                      checks, stack image digests, leftovers, verdict; the diff; self-checks
  report.txt          the same, for people (also in the service's journal)
  issues-dry-run.md   the issues it would have opened or closed (dry-run only, when any)
  logs/<walkthrough>@<version>[@<ref>]/
                      pull.log 0-preflight.log 1-clean.log 2-all.log 3-gates.log 4-clean.log
                      gates/  (the walkthrough's out/gates/)
```

Nights are kept for 30 days (`E2E_KEEP_NIGHTS`); the worktrees are deleted after each night
(`E2E_KEEP_WORK=1` keeps them).

## Diff and reporting

Each night is compared with the previous one: new `FAIL`, new `PASS` (the last `PASS` or
`FAIL` before tonight, skipping `BLOCKED` nights), steps more than 2x slower than the baseline
(`E2E_SLOW_FACTOR`; steps under 60 s ignored), and moved image digests.

Issues on `artifact-keeper/walkthroughs`, one per walkthrough and version:

- a new `FAIL` opens `[e2e] <walkthrough> fails on <release|dev>[ (<ref>)]`, unless an issue with
  that title is already open; a `FAIL` that persists posts nothing;
- a `PASS` comments on the open issue and closes it;
- `BLOCKED` never opens or closes anything;
- the runner's own health (a missed night, a night with no results, a secret found in a log)
  goes to one issue, `[e2e] nightly runner health`.

`E2E_REPORT=dry-run` (the default) only prints the title and body it would post, to the
journal and to `issues-dry-run.md`. `E2E_REPORT=github` posts them with the token in
`~/.config/ak-e2e/gh-token`; without that file it falls back to a dry run and says so.

## Install

On the runner host, from a checkout of this repository:

```bash
e2e/install.sh
```

It copies the runner to `~/ak-e2e/runner/`, installs `ak-e2e.service` and `ak-e2e.timer` in
`~/.config/systemd/user/`, creates `~/.config/ak-e2e/config.env` from `config.example.env`
if there is none, and runs `systemctl --user daemon-reload`. It does not enable the timer.
The host needs rootless podman with `podman compose`, git, make, python3 (3.11 or newer),
`ss`, and lingering enabled for the user (`loginctl enable-linger`), so the timer runs
without a login. Host tools a walkthrough needs (its `requires` in `walkthroughs.toml`) can go
in `~/ak-e2e/bin/`, which the runner puts first on `PATH`; on grace that holds cosign v3.1.3
(checksum-verified release binary) for the conda walkthrough.

Run one night by hand:

```bash
systemctl --user start --no-block ak-e2e.service
journalctl --user -fu ak-e2e.service
```

## Enable the timer

```bash
systemctl --user enable --now ak-e2e.timer
systemctl --user list-timers ak-e2e.timer
```

It fires at 02:00 local time; `Persistent=true` runs a missed night when the host comes back.

## Configuration

Non-secret settings: `~/.config/ak-e2e/config.env` (see `config.example.env`).

| Variable | Default | |
|---|---|---|
| `E2E_REPORT` | `dry-run` | `github` posts issues |
| `E2E_EXTRA_REFS` | | branches to test besides `main` and PRs labelled `e2e` |
| `E2E_VERSIONS` | `release dev` | tracks, in run order |
| `E2E_RELEASE_BACKEND_TAG`, `E2E_RELEASE_WEB_TAG` | latest releases | pin a track's tags |
| `E2E_ONLY`, `E2E_ONLY_RUNS` | | limit to walkthroughs, or to `slug@track` pairs (testing) |
| `E2E_PATCH_DIR` | | apply `<dir>/<ref>.patch` after checkout (testing changes before they are pushed; recorded in `summary.json`) |
| `E2E_HOME` | `~/ak-e2e` | where nights are written |

Secrets: one file each in `~/.config/ak-e2e/`, mode 600 (the directory 700). The runner reads
them itself, passes each only to the walkthroughs that list it in `walkthroughs.toml`, by
environment variable, and greps the night's files for them afterwards. A file that is
readable by others is ignored. A missing secret makes the checks that need it `BLOCKED`.

| File | Variable | Used by |
|---|---|---|
| `gh-token` | `GH_TOKEN` | issue reporting (`E2E_REPORT=github`); a fine-grained token with Issues read and write on `artifact-keeper/walkthroughs`. The runner never passes it to a walkthrough. |
| `claude-code-oauth-token` | `CLAUDE_CODE_OAUTH_TOKEN` | `private-agent-plugin-marketplace`, gate G4 (a signed-in Claude Code session); from `claude setup-token` |

```bash
install -m 600 /dev/null ~/.config/ak-e2e/claude-code-oauth-token
$EDITOR ~/.config/ak-e2e/claude-code-oauth-token
```

npm: the runner gives walkthroughs `npm_config_registry=https://registry.npmjs.org/` and an
`NPM_CONFIG_USERCONFIG` of its own, so the host's `~/.npmrc` is never read.

## Add a walkthrough

Follow the [e2e contract](../CONTRIBUTING.md#the-e2e-contract) and add a table to
`walkthroughs.toml` with the names of the containers, volumes and networks the stack creates,
its ports and subnets. Without it the runner reports the walkthrough as `BLOCKED(unregistered)`
rather than run `make clean` on what might be someone else's containers.
