#!/usr/bin/env bash
# Host preflight: checks what the pipeline needs before anything is started.
# Read-only; changes nothing. Exit 0 if no check FAILed (WARNs are allowed).
#   make preflight            # or deploy/preflight.sh
#   SSH_KEY=~/.ssh/other make preflight
set -uo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PUBKEY="${SSH_PUBKEY:-$SSH_KEY.pub}"
AK_PORT="${AK_PORT:-30080}"
KS_PORT="${KS_PORT:-8000}"
SSH_PORT="${SSH_PORT:-2222}"
MIN_MAP_COUNT=262144   # OpenSearch's documented minimum

fails=0 warns=0
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

echo "== tools"
for t in podman skopeo cosign gpg jq curl python3 qemu-system-x86_64 qemu-img; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else fail "$t not found in PATH"; fi
done
if podman compose version >/dev/null 2>&1; then ok "podman compose"
else fail "podman compose has no provider (install docker-compose or podman-compose)"; fi
if [[ -r /usr/share/edk2/ovmf/OVMF_CODE.fd ]]; then ok "OVMF firmware (edk2-ovmf)"
else fail "/usr/share/edk2/ovmf/OVMF_CODE.fd missing (install edk2-ovmf, or set OVMF_CODE/OVMF_VARS_TEMPLATE)"; fi
if command -v uv >/dev/null 2>&1; then ok "uv (docs site only)"; else warn "uv not found (only needed to build the docs site)"; fi

echo "== rootless podman"
if [[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == true ]]; then
  ok "podman runs rootless ($(podman --version 2>/dev/null))"
else
  fail "podman is not running rootless for this user (podman info failed or reports rootful)"
fi

echo "== KVM"
if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok "/dev/kvm usable: VMs run with -accel kvm"
  else warn "/dev/kvm exists but is not read-write for $(id -un) (kvm group membership?); VMs will use TCG, about 5x slower"; fi
else
  warn "no /dev/kvm: VMs will use software emulation (TCG), about 5x slower; see the Environment page"
fi

echo "== vm.max_map_count (OpenSearch)"
mmc="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if (( mmc >= MIN_MAP_COUNT )); then ok "vm.max_map_count = $mmc"
else fail "vm.max_map_count = $mmc, OpenSearch needs >= $MIN_MAP_COUNT (an administrator must raise it once)"; fi

echo "== SSH key"
if [[ -r "$SSH_KEY" ]]; then ok "private key $SSH_KEY"; else fail "private key $SSH_KEY not readable (set SSH_KEY=)"; fi
if [[ -r "$SSH_PUBKEY" ]]; then ok "public key $SSH_PUBKEY"; else fail "public key $SSH_PUBKEY not readable (set SSH_PUBKEY=)"; fi

echo "== ports"
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    [[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]]
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}
if port_in_use "$AK_PORT"; then
  if curl -fsS -o /dev/null "http://localhost:$AK_PORT/readyz" 2>/dev/null; then
    ok "$AK_PORT in use by a running Artifact Keeper (/readyz answers)"
  else
    fail "$AK_PORT is in use by something else (Artifact Keeper needs it; or set HTTP_PORT in registry/.env)"
  fi
else
  ok "$AK_PORT free (Artifact Keeper)"
fi
for p in "$KS_PORT:kickstart server, KS_PORT" "$SSH_PORT:VM ssh forward, SSH_PORT"; do
  n="${p%%:*}" what="${p#*:}"
  if port_in_use "$n"; then
    if [[ -f "$(dirname "$0")/state/qemu.pid" ]] && kill -0 "$(cat "$(dirname "$0")/state/qemu.pid")" 2>/dev/null; then
      warn "$n in use, probably by the running VM ($what)"
    else
      fail "$n is in use ($what)"
    fi
  else
    ok "$n free ($what)"
  fi
done

echo
if (( fails )); then
  echo "preflight: $fails FAIL, $warns WARN"
  exit 1
fi
echo "preflight: all required checks passed ($warns WARN)"
