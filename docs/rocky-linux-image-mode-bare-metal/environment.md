# Environment setup

Everything runs as an ordinary user: rootless podman for Artifact Keeper and all image
builds, and an unprivileged QEMU process for the edge node (a QEMU VM in this PoC).
**No sudo for the pipeline itself; two host settings may need an administrator once
(kvm group membership, `vm.max_map_count`).** It was developed on Fedora 44; any recent
Linux with the tools below should work.

## Requirements

On Fedora:

```bash
sudo dnf install podman skopeo cosign qemu-system-x86 edk2-ovmf curl python3 jq gnupg2 docker-compose uv
```

`docker-compose` is only there as the provider behind `podman compose` (`podman-compose`
works too); `uv` is only needed to build this documentation site.

| Tool | Used for | Tested with |
|---|---|---|
| podman 5.x (rootless) | Artifact Keeper stack, base, RPM and image builds | 5.8.7 |
| `podman compose` | starting the Artifact Keeper compose file | delegating to docker-compose v5.5.1 |
| skopeo | inspecting, copying and promoting tags in the registry | 1.22.3 |
| cosign | signing and verifying images | 3.1.3 (see the note below) |
| gpg | RPM signing key, repodata signature checks | GnuPG 2.4.9 |
| jq, curl, python3 | scripts, API calls, serving the kickstart | |
| qemu-system-x86_64, edk2-ovmf | the edge node VM and its UEFI firmware | QEMU 10.2.2 |
| uv | building this documentation site | 0.12 |

Other requirements:

- **SSH key pair.** The deploy scripts use `SSH_KEY` for the private key (default
  `~/.ssh/id_ed25519`) and `SSH_PUBKEY` for the public key (default `$SSH_KEY.pub`). The
  public key is injected into the node with the kickstart `sshkey` command; root's password
  is locked, so this key is the only way in.
- **RAM:** about 8 GB free for the VM (6 vCPU, 8 GiB by default; `VM_SMP`, `VM_MEM`), plus
  what the Artifact Keeper stack uses (Postgres, OpenSearch, backend, web, Caddy).
- **Disk:** about 7 GB for images and install media (including the cached 750 MB installer
  stage2), plus the VM's 40 GB sparse qcow2 (`VM_DISK_SIZE`) and Artifact Keeper's volumes.

!!! note "cosign version"
    cosign 3 signs in the Sigstore bundle format via the OCI referrers API by default.
    podman, skopeo, bootc and the installer cannot see that format, so `signing/lib.sh`
    passes the deprecated `--new-bundle-format=false --use-signing-config=false --tlog-upload=false`
    flags. Pin cosign (3.1.3 works) until containers-image reads bundles. Details in the
    [signing log](findings-signing.md#5-image-signing-and-how-ak-stores-cosign-signatures).

## Preflight

`make preflight` (`deploy/preflight.sh`) checks the host before anything is started and
changes nothing:

- the tools above, a `podman compose` provider and the OVMF firmware;
- that podman runs rootless for your user;
- whether `/dev/kvm` exists and is read-write for you (a warning, not a failure: see below);
- `vm.max_map_count` is at least 262144 (OpenSearch);
- the SSH key pair at `SSH_KEY` / `SSH_PUBKEY`;
- ports 30080 (free, or already answering as Artifact Keeper), 8000 and 2222 (free, or held
  by the running VM).

```text
== KVM
  OK    /dev/kvm usable: VMs run with -accel kvm
== vm.max_map_count (OpenSearch)
  OK    vm.max_map_count = 2147483642
...
preflight: all required checks passed (0 WARN)
```

It exits non-zero if any check reports `FAIL`. `SSH_KEY`, `SSH_PUBKEY`, `KS_PORT` and
`SSH_PORT` are honoured as in the rest of the harness.

## Rootless podman

- **Compose.** `registry/up.sh` uses `podman compose`. The stock Artifact Keeper compose
  file (fixed `172.30.0.0/24` network, `depends_on.required: false`,
  `service_completed_successfully`, `!reset` in the override) worked without changes.
  If your compose provider talks to the podman socket, start it with
  `systemctl --user enable --now podman.socket`.
- **Networking.** Rootless podman 5 uses **pasta**. From inside a container or a
  `podman build`, the host is `host.containers.internal`; every build in this repository
  reaches Artifact Keeper as `host.containers.internal:30080`.
- **Short names.** Rootless podman's `short-name-mode = "enforcing"` matched a short
  `postgres:18-alpine` against an unrelated locally cached image, so the compose override
  fully qualifies every image (`docker.io/library/...`).
- **OpenSearch** needs `vm.max_map_count` of at least 262144. If `make preflight` flags it,
  an administrator raises it once (`sysctl -w vm.max_map_count=262144`, plus a file in
  `/etc/sysctl.d/` to keep it).
- **Builds** that run the RESF recipe need `--security-opt=label=disable --cap-add=all
  --device /dev/fuse`, which rootless podman allows as is.

## KVM or not

No `/dev/kvm`? Everything still works under software emulation (QEMU TCG), about 5x slower
(install about 10 minutes, power-on to a working cluster about 17 minutes). `deploy/lib.sh`
picks `-accel kvm -cpu host` when `/dev/kvm` is read-write for you and
`-accel tcg,thread=multi -cpu max` otherwise; the harness timeouts are sized for TCG.

To enable KVM, check the kernel log:

```bash
journalctl -k -b | grep -iE 'kvm|svm|vmx'
```

`kvm_amd: SVM disabled (by BIOS) in MSR_VM_CR` (or, on Intel, `kvm_intel` reporting VMX
disabled by BIOS) means the CPU supports virtualization but the firmware has it switched off:
enable **SVM Mode** / **AMD-V** or **Intel Virtualization Technology (VT-x)** in the BIOS or
UEFI setup and reboot. If `/dev/kvm` then exists but is group-only, your user must be in the
`kvm` group (an administrator change).

Stage-by-stage numbers for both modes are on the [Timings](timings.md) page.

## Files the scripts write under `~/.config/containers`

The build host verifies the base image's signature before building on it.
`image/setup-host.sh` (run by the image build) writes only under
`${XDG_CONFIG_HOME:-~/.config}/containers/`:

| File | Why |
|---|---|
| `registries.conf.d/50-artifact-keeper-local.conf` | marks `localhost:30080` insecure (plain HTTP), so `FROM`, pull and push work without `--tls-verify=false` |
| `policy.json` | a copy of the system policy plus a rule requiring our cosign signature for `localhost:30080/oci-bootc` |
| `registries.d/ak-oci-bootc.yaml` | tells containers-image to look for cosign's `sha256-<digest>.sig` tags |
| `registries.d/*.yaml` (symlinks) | links to each `/etc/containers/registries.d/*.yaml`; see the warning below |

??? example "Content of the three files"

    `registries.conf.d/50-artifact-keeper-local.conf`:

    ```toml
    [[registry]]
    location = "localhost:30080"
    insecure = true
    ```

    `policy.json` (added scope; the rest is a copy of `/etc/containers/policy.json`, or an
    `insecureAcceptAnything` default if there is none):

    ```json
    { "transports": { "docker": {
      "localhost:30080/oci-bootc": [{
        "type": "sigstoreSigned",
        "keyPath": "<repo>/signing/keys/pub/edge-cosign.pub",
        "signedIdentity": { "type": "matchRepository" }
      }]
    }}}
    ```

    `registries.d/ak-oci-bootc.yaml`:

    ```yaml
    docker:
      localhost:30080/oci-bootc:
        use-sigstore-attachments: true
    ```

!!! warning "User-level files replace the system ones"
    A user-level `~/.config/containers/policy.json` **replaces** `/etc/containers/policy.json`
    for your user, and a user-level `registries.d/` **replaces** `/etc/containers/registries.d/`.
    That is why the script starts from a copy of the system policy and symlinks the system
    `registries.d` files next to its own. If your system policy changes later, your copy
    does not follow it.

The `matchRepository` identity is deliberate: cosign records a tag-less identity
(`localhost:30080/oci-bootc/rocky-edge`), and the default `matchRepoDigestOrExact` rejects
it with `Signature for identity ... is not accepted`.

### Undoing it

```bash
C="${XDG_CONFIG_HOME:-$HOME/.config}/containers"
rm -f "$C/registries.conf.d/50-artifact-keeper-local.conf"
rm -f "$C/registries.d/ak-oci-bootc.yaml"
# the symlinks to /etc/containers/registries.d/*.yaml (only the links, not the targets)
find "$C/registries.d" -maxdepth 1 -type l -lname '/etc/containers/registries.d/*' -delete
rmdir "$C/registries.d" 2>/dev/null || true
# policy.json: delete it if setup-host.sh created it (the system policy applies again) ...
rm -f "$C/policy.json"
# ... or, if you had your own before, just drop the added scope:
# jq 'del(.transports.docker["localhost:30080/oci-bootc"])' "$C/policy.json" > p && mv p "$C/policy.json"
```

### Other generated state (all gitignored)

| Path | What |
|---|---|
| `registry/.env` | admin password (user `admin`), JWT secret, webhook key, generated by `up.sh` (mode 600) |
| `registry/.ak-token` | CI API token (`read:artifacts`, `write:artifacts`, 30 days), reused while valid |
| `registry/out/` | generated `edge.repo`, `edge.repo.in`, `README-urls.md` |
| `signing/keys/` | cosign key pair, RPM GPG home, cosign's registry auth, public keys (mode 700; PoC keys have no passphrase) |
| `deploy/cache/` | Rocky 10.2 pxeboot `vmlinuz`, `initrd.img`, stage2 `install.img`, sha256-checked |
| `deploy/state/` | VM disk, OVMF vars, serial logs, `timings.log`, rendered kickstart (contains your public key) |

`./registry/down.sh -v` deletes Artifact Keeper's volumes; `make vm-clean` deletes
`deploy/state/` (`CLEAN_CACHE=1` also drops the media cache); `make clean` removes the
local build scratch directories.

## Ports

| Port | Bound by | Use |
|---|---|---|
| `30080` | Caddy in the Artifact Keeper stack | everything: web UI, `/api/v1`, `/rpm/<key>`, OCI `/v2`. The VM reaches it as `10.0.2.2:30080` |
| `30443` | Caddy | HTTPS with Caddy's internal CA for `localhost`; not used here |
| `8000` | `deploy/serve-ks.sh` (`python3 -m http.server` on `0.0.0.0`) | kickstart and the cached installer stage2, during `vm-install` only |
| `2222` | QEMU user-mode `hostfwd` | ssh to the node: `ssh -p 2222 root@localhost` (`make vm-ssh`) |
| `30090` | inside the VM | the nginx-demo NodePort (not forwarded to the host by default) |

Change them with `HTTP_PORT` / `HTTPS_PORT` in `registry/.env`, and `KS_PORT` / `SSH_PORT`
for the harness. Postgres, OpenSearch, the backend (8080) and the web UI (3000) are only
reachable on the compose network; the stock compose file publishes Postgres and
OpenSearch on the host, and the override in `registry/compose/compose.override.yml` removes that.
