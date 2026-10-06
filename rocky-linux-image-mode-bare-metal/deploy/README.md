# deploy/ — kickstart a QEMU "bare-metal" node from Artifact Keeper

This directory turns the bootc edge image in Artifact Keeper
(`oci-bootc/rocky-edge:10`) into a running node, then drives day-2
upgrade and rollback. The node is a QEMU VM with UEFI (OVMF), a virtio disk
and user-mode networking, so it sees the host (and Artifact Keeper) as
`10.0.2.2`. Nothing here needs root.

## Flow

```
make preflight     # host checks: tools, rootless podman, /dev/kvm, vm.max_map_count, SSH key, ports
make vm-install    # Anaconda netboot + kickstart -> ostreecontainer pull from AK -> disk
make vm-boot       # boot disk in background, wait for ssh, wait for node Ready, show status
make vm-verify     # nginx-demo Running, image pulled via AK's oci-dockerhub-proxy
make vm-upgrade-unsigned  # negative: retag rocky-edge:unsigned-test -> :10, bootc upgrade MUST fail
                          #   with the signature error, node stays on its image; tag restored
make vm-upgrade    # retag rocky-edge:10.2-4 -> :10 in AK, bootc upgrade, reboot, verify
make vm-rollback   # bootc rollback, reboot, verify
make vm-ssh        # ssh -p 2222 root@localhost
make vm-status     # one-screen summary
make vm-stop       # clean poweroff
make vm-clean      # stop + delete deploy/state (CLEAN_CACHE=1 also drops the media cache)
make vm-all        # vm-install vm-boot vm-verify vm-upgrade-unsigned vm-upgrade vm-verify vm-rollback vm-verify
```

`make` builds a goal only once per invocation, so repeating `vm-verify` on one command
line runs it once; `vm-all` runs the scripts in sequence instead.

All targets are thin wrappers over the scripts of the same name. Every
setting in `lib.sh` can be overridden as an environment or make variable:

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE` | `rocky-edge:10` | image (under `IMAGE_REPO`) the node installs and tracks |
| `IMAGE_REPO` | `oci-bootc` | Artifact Keeper repo key |
| `REGISTRY` | `10.0.2.2:30080` | registry as seen from the VM |
| `HOST_REGISTRY` | `localhost:30080` | registry as seen from this host (skopeo) |
| `PROMOTE_FROM` | `rocky-edge:10.2-4` | `vm-upgrade` retags this to `IMAGE` first; empty = skip |
| `UNSIGNED_FROM` | `rocky-edge:unsigned-test` | what `vm-upgrade-unsigned` promotes |
| `KEY_URL` | `http://$REGISTRY/api/v1/repositories/raw-edge-keys/download/edge-cosign.pub` | cosign public key fetched by kickstart `%pre` |
| `STAGE2` | `local` | `local`: installer stage2 (`install.img`, 750 MB) cached in `cache/` and served by `serve-ks.sh`; `mirror`: fetched from dl.rockylinux.org |
| `KS_TEMPLATE` | `deploy/ks.cfg.in` | kickstart template (experiments) |
| `VM_SMP` / `VM_MEM` | `6` / `8192` | vCPUs / MiB |
| `VM_DISK_SIZE` | `40G` | qcow2 virtual size |
| `SSH_PORT` / `KS_PORT` | `2222` / `8000` | host ports (ssh forward, kickstart http) |
| `SSH_KEY` | `~/.ssh/id_ed25519` | private key; `SSH_PUBKEY` defaults to `$SSH_KEY.pub` |
| `NODE_HOSTNAME` | `edge-node-01` | kickstart hostname |
| `INSTALL_TIMEOUT` | `2400` | seconds before `vm-install` gives up |
| `WAIT_READY` | `1200` | seconds `vm-boot` waits for the k8s node to be Ready (0 = skip) |

## Files

| File | What |
|---|---|
| `ks.cfg.in` | kickstart template (`@REGISTRY@`, `@IMAGE@`, `@IMAGE_REPO@`, `@SIGNED_REPO@`, `@KEY_URL@`, `@SSH_KEY@`, `@HOSTNAME@`) |
| `render-ks.sh` | renders it to `state/www/ks.cfg`, reading the public key at render time |
| `serve-ks.sh` | `python3 -m http.server` on `0.0.0.0:8000` serving only `state/www/` (ks.cfg and, with `STAGE2=local`, `os/.treeinfo` + `os/images/install.img` symlinks) |
| `fetch-media.sh` | caches Rocky 10.2 pxeboot `vmlinuz`/`initrd.img` (and stage2 `install.img`) in `cache/`, sha256-checked against `.treeinfo` |
| `vm-install.sh` | fresh qcow2 + OVMF vars, headless install, follows Anaconda milestones in the serial log; logs whether the image is cosign-signed; aborts within seconds (exit 1) when the serial log shows a signature/policy error |
| `vm-upgrade-unsigned.sh` | day-2 negative test (see Flow) |
| `vm-boot.sh` | daemonized QEMU with `hostfwd tcp::2222-:22`, status report |
| `vm-verify.sh` | workload + pull-through checks (guest and Artifact Keeper API) |
| `vm-upgrade.sh`, `vm-rollback.sh` | day-2, with digest assertions |
| `vm-ssh.sh`, `vm-status.sh`, `vm-stop.sh`, `vm-clean.sh` | the rest |
| `lib.sh`, `k8s-detect.sh` | shared settings/helpers; RKE2 vs k3s detection |
| `preflight.sh` | read-only host checks (`make preflight`) |
| `deploy.mk` | make targets, included by the root `Makefile` |

`state/` (disk, OVMF vars, serial logs, `timings.log`, pid files, rendered
kickstart) and `cache/` (install media) are gitignored.

## Why it looks like this

- **No ISO.** The installer is the mirror's pxeboot kernel/initrd with
  `inst.stage2=http://10.0.2.2:8000/os/` (the mirror's `install.img`, cached and
  sha256-checked; `STAGE2=mirror` uses
  `https://dl.rockylinux.org/pub/rocky/10.2/BaseOS/x86_64/os/` directly), which is also how a
  PXE/iPXE bare-metal deployment would boot it.
- **`ostreecontainer`, not `bootc`.** The kickstart `bootc` command on Rocky
  10.2 leaves root's `authorized_keys` and `/etc/resolv.conf` mislabelled (SELinux AVCs for
  sshd and NetworkManager on first boot). `ostreecontainer` labels correctly
  ([evidence](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/findings-deploy/#install-method-ostreecontainer-vs-the-bootc-kickstart-command)).
- **Signatures are enforced by `policy.json`, not by a kickstart flag.** There is no
  `--no-signature-verification`. `%pre` writes the installer's
  `/etc/containers/policy.json` (default `reject`; `@REGISTRY@/oci-bootc/rocky-edge` needs a
  cosign signature by the edge key, `signedIdentity: exactRepository` =
  `localhost:30080/oci-bootc/rocky-edge`, the name the signer pushed to), a `registries.d`
  entry enabling the `sha256-<digest>.sig` lookup, and the public key fetched with `curl`
  from Artifact Keeper's `raw-edge-keys` repo. Measured: with this policy an unsigned image
  is refused even if `--no-signature-verification` is added back; with the installer's stock
  policy an unsigned image installs even without the flag (docs/findings-signing.md).
  `%post` writes the same three files into the installed system only if the image lacks them
  (it ships them), so they stay image-managed `/etc` files that later images can update.
  `bootc upgrade` uses the image's policy: an unsigned `:10` fails with
  `A signature was required, but no signature exists` and nothing is staged.
- **Insecure registry.** Artifact Keeper is plain HTTP in this PoC. `%pre`
  writes a `registries.conf.d` drop-in so Anaconda can pull; `%post` writes the
  same into the installed `/etc` so `bootc upgrade` works even if an image
  forgets to bake it. Signatures protect the content; TLS is a separate step.
- **KVM vs TCG.** With a usable `/dev/kvm` the scripts use `-accel kvm -cpu host`
  automatically, otherwise TCG (`-cpu max`, `thread=multi`); the timeouts are sized for TCG.
  Numbers: [Timings](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/timings/).
- **Local stage2.** The 750 MB `install.img` is cached and served next to the kickstart,
  because downloading it from the mirror dominated an install under KVM
  (`STAGE2=mirror` for the old behaviour).
- **SSH waits are gentle.** Under slirp every host connection arrives from
  `10.0.2.2`; OpenSSH's `PerSourcePenalties` can block that source after
  repeated failed or aborted attempts. The wait loop uses `BatchMode=yes`,
  the right key only, and sleeps 10-15 s between tries.
- **Root is key-only.** `rootpw --lock` + kickstart `sshkey` with the
  operator's own public key; nothing secret is in git.
