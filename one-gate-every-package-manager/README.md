# One gate for every package manager

Code for the walkthrough
[One gate for every package manager](https://artifact-keeper.github.io/walkthroughs/one-gate-every-package-manager/).
The narrative lives in [`docs/one-gate-every-package-manager/`](../docs/one-gate-every-package-manager/);
everything it runs lives here. Run every command below from this directory.

> **An example, not a complete defense.** This shows one way to put one scan gate in front of
> several package managers with Artifact Keeper. The configuration is an example, built and
> tested in a lab. It does not cover every edge case or attack, and it is not a hardened
> production setup; known gaps are in the
> [findings](../docs/one-gate-every-package-manager/findings.md). Review and adapt it for your
> environment, and use it alongside your other controls, not instead of them.

> **Draft, run against `main`.** Artifact Keeper 1.12.0 is not released. The run recorded in
> the docs used the latest `main` image from ghcr.io (digest in `registry/compose/VERSIONS` and
> the docs' results page); several fixes planned for 1.12.0 are not merged, and the pages say
> which step waits on which.

Five package managers, one registry, one policy: `go`, `cargo`, `npm`, `apt` and `apk` each
point at a Remote repository on [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper)
at `ak.internal`. The registry scans every file it fetches from the public upstream and, once
you tell it to, refuses the ones with a high or critical advisory. The story is the rollout:

| Step | What happens | Make target |
|---|---|---|
| 1 | The registry, five proxies, five clients | `registry-up bootstrap images` |
| 2 | Record only: scan and record every pull, withhold nothing; see what would be blocked | `record baseline known-bad preview` |
| 3 | Review the dashboard, the blocked list, the admin queues, the audit rows | `review` |
| 4 | Enforce: fail closed, and lock the policy | `enforce lock` then `baseline known-bad review` |
| 5 | A legitimate exception, hosted (acknowledge) and proxied (no exception today) | `exception` |
| 6 | Prove it fails safely | `gates` |

```
proxy.golang.org  ─┐                                              ┌─ go     (GOPROXY)
index.crates.io   ─┤                                              ├─ cargo  (source replacement)
registry.npmjs.org┼─> Artifact Keeper (ak.internal) ──────────────┼─ npm    (registry=)
deb.debian.org    ─┤   scan-on-proxy: record_only -> fail_closed  ├─ apt    (deb https://ak.internal/...)
dl-cdn.alpinelinux┘   one threshold, one blocked list, one audit  └─ apk    (/etc/apk/repositories)
```

## Layout

| Path | What |
|---|---|
| `registry/` | Artifact Keeper (upstream compose + override, rootless podman), Caddy as `https://ak.internal` with an internal CA, `up.sh`, idempotent `bootstrap.sh` (the five proxies, `npm-internal` and its scan policy, tokens, index signing keys) |
| `clients/` | `run.sh` runs one client in its official image on the registry network with the CA and the config in `config/`; `baseline/` the ordinary projects; `known-bad.sh` one advisory-bearing package per format; `probe.sh` shows exactly what the gate answered |
| `policy/` | `mode.sh` (record_only, fail_open, fail_closed, off), `lock.sh`, `preview.sh` (what would be blocked), `review.sh` (dashboard, blocked list, hold queues, scores, audit) |
| `exception/` | `vendor.sh`, `acknowledge.sh`, `rescan.sh` (the hosted exception and #5153), `proxied.sh` (#5143, no proxied exception) |
| `gates/` | G1-G9 as runnable checks (PASS / FAIL / BLOCKED(#issue)) |

## Requirements

- Linux with rootless podman 5.x, and `podman compose` backed by docker-compose 2.24 or newer
  (the override uses `!reset` and `!override`; podman-compose does not support them). Compose
  talks to the user podman socket: `systemctl --user enable --now podman.socket`.
- bash 4+, GNU make, curl, jq, openssl, `column` (util-linux or bsdextrautils).
- About 6 GB of RAM and 10 GB of disk. No sudo.
- A free subnet 172.31.60.0/24 and a free port 127.0.0.1:30446, or set `AK_NET_SUBNET` and
  `HTTPS_PORT` in `registry/.env`.
- Internet access from the host: the registry proxies five public upstreams, and the host's
  podman pulls the stack's images from ghcr.io and Docker Hub and the five client images.

## Run it

```bash
make all          # registry, proxies, record-only, baselines, preview, enforce, review, exception
make gates        # G1-G9, evidence in out/gates/
make screens-ready
```

`make clean` deletes the stack, its volumes, the network, the tokens and `registry/.env`. The
step-by-step targets are listed by `make help` and used one at a time in the docs.

Admin UI: https://127.0.0.1:30446 (user `admin`, password generated into `registry/.env`; the
certificate is from the stack's own CA, `registry/out/ak-internal-ca.crt`).
Generated secrets, tokens and outputs are gitignored.

## License

MIT, see the repository's [LICENSE](../LICENSE).
