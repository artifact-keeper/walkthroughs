# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this
# Common settings for the deploy/ scripts. Every value can be overridden from the
# environment (or as make variables: `make vm-install IMAGE=rocky-edge:dev`).
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
STATE_DIR="${STATE_DIR:-$DEPLOY_DIR/state}"   # disk, OVMF vars, logs, pid files (gitignored)
CACHE_DIR="${CACHE_DIR:-$DEPLOY_DIR/cache}"   # pxeboot kernel/initrd (gitignored)
WWW_DIR="$STATE_DIR/www"                      # only ks.cfg lives here; this is what http.server exposes

# Registry as seen from the VM (QEMU user-mode net: host = 10.0.2.2) and from this host.
REGISTRY="${REGISTRY:-10.0.2.2:30080}"
HOST_REGISTRY="${HOST_REGISTRY:-localhost:30080}"
IMAGE_REPO="${IMAGE_REPO:-oci-bootc}"
IMAGE="${IMAGE:-rocky-edge:10}"
IMAGE_REF="$IMAGE_REPO/$IMAGE"
NODE_HOSTNAME="${NODE_HOSTNAME:-edge-node-01}"
# cosign public key in Artifact Keeper (signing/publish-keys.sh), fetched by kickstart %pre.
KEY_URL="${KEY_URL:-http://$REGISTRY/api/v1/repositories/raw-edge-keys/download/edge-cosign.pub}"

# Install media: Rocky 10.2 pxeboot kernel/initrd + stage2 straight from the mirror.
ROCKY_TREE="${ROCKY_TREE:-https://dl.rockylinux.org/pub/rocky/10.2/BaseOS/x86_64/os}"
# Where the installer gets stage2 (install.img, 750 MB): "local" = cached by
# fetch-media.sh and served by serve-ks.sh (default), "mirror" = straight from ROCKY_TREE.
STAGE2="${STAGE2:-local}"

# VM shape. TCG is slow; more vCPUs help (thread=multi).
VM_SMP="${VM_SMP:-6}"
VM_MEM="${VM_MEM:-8192}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
SSH_PORT="${SSH_PORT:-2222}"
KS_PORT="${KS_PORT:-8000}"
KS_BIND="${KS_BIND:-0.0.0.0}"
if [[ "$STAGE2" == local ]]; then STAGE2_URL="http://10.0.2.2:$KS_PORT/os/"; else STAGE2_URL="$ROCKY_TREE/"; fi
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PUBKEY="${SSH_PUBKEY:-$SSH_KEY.pub}"

OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/edk2/ovmf/OVMF_VARS.fd}"

DISK="$STATE_DIR/disk.qcow2"
VARS="$STATE_DIR/OVMF_VARS.fd"
QEMU_PIDFILE="$STATE_DIR/qemu.pid"
QMP_SOCK="$STATE_DIR/qmp.sock"
TIMINGS="$STATE_DIR/timings.log"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
stamp() { printf '%s %s\n' "$(date -Is)" "$*" >> "$TIMINGS"; log "$*"; }

# /dev/kvm if usable, otherwise TCG (AMD-V disabled on the reference workstation).
qemu_accel_args() {
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    echo "-accel kvm -cpu host"
  else
    echo "-accel tcg,thread=multi -cpu max"
  fi
}

# Arguments shared by install and boot. Network args are added by the caller.
qemu_common_args() {
  # shellcheck disable=SC2046
  printf '%s\n' -machine q35 $(qemu_accel_args) -smp "$VM_SMP" -m "$VM_MEM" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$VARS" \
    -drive "file=$DISK,if=virtio,format=qcow2,discard=unmap" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -display none \
    -qmp "unix:$QMP_SOCK,server=on,wait=off"
}

vm_pid() {
  [[ -f "$QEMU_PIDFILE" ]] || return 1
  local pid; pid="$(cat "$QEMU_PIDFILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
vm_running() { vm_pid >/dev/null; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15
          -i "$SSH_KEY" -p "$SSH_PORT")
vssh() { ssh "${SSH_OPTS[@]}" root@localhost "$@"; }

# Wait until sshd accepts our key. One attempt per $2 seconds (default 15) so a
# booting sshd never sees a burst of half-open connections (OpenSSH PerSourcePenalties
# would otherwise block 10.0.2.2, which is every host-side connection under slirp).
wait_ssh() {
  local timeout="${1:-900}" interval="${2:-15}" start=$SECONDS
  log "waiting for ssh on localhost:$SSH_PORT (timeout ${timeout}s)"
  until vssh true 2>/dev/null; do
    vm_running || die "QEMU exited while waiting for ssh (see $STATE_DIR/boot-serial.log)"
    (( SECONDS - start > timeout )) && die "ssh not reachable after ${timeout}s"
    sleep "$interval"
  done
  log "ssh up after $((SECONDS - start))s"
}

boot_id() { vssh cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

# Reboot the guest and wait until it comes back with a new boot_id.
reboot_and_wait() {
  local old new start=$SECONDS
  old="$(boot_id)"
  vssh 'systemctl reboot' || true
  sleep 20
  while :; do
    new="$(boot_id)"
    [[ -n "$new" && "$new" != "$old" ]] && break
    vm_running || die "QEMU exited during reboot"
    (( SECONDS - start > 1200 )) && die "guest did not come back within 20 min"
    sleep 15
  done
  log "guest back after $((SECONDS - start))s (boot_id $new)"
}

# Run a QMP command against the running VM (no socat dependency).
qmp() {
  python3 -I - "$QMP_SOCK" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
f = s.makefile("rw")
f.readline()
for cmd in ("qmp_capabilities", sys.argv[2]):
    f.write(json.dumps({"execute": cmd}) + "\n"); f.flush()
    print(f.readline().strip())
PY
}

mkdir -p "$STATE_DIR" "$CACHE_DIR"
