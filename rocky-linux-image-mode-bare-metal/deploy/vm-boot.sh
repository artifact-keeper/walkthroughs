#!/usr/bin/env bash
# Boot the installed disk in the background (ssh on localhost:$SSH_PORT), wait for
# ssh, then report image/SELinux/Kubernetes state. Detects RKE2 or k3s.
#   WAIT_READY=1200   seconds to wait for the node to be Ready (0 = don't wait)
source "$(dirname "$0")/lib.sh"
WAIT_READY="${WAIT_READY:-1200}"
SERIAL="$STATE_DIR/boot-serial.log"

[[ -f "$DISK" ]] || die "no disk at $DISK; run 'make vm-install' first"

if vm_running; then
  log "VM already running (pid $(vm_pid))"
else
  mapfile -t COMMON < <(qemu_common_args)
  stamp "boot: qemu start"
  qemu-system-x86_64 "${COMMON[@]}" \
    -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22" \
    -serial "file:$SERIAL" \
    -pidfile "$QEMU_PIDFILE" -daemonize
  log "QEMU pid $(vm_pid); serial log $SERIAL"
fi
start=$SECONDS
wait_ssh 1200
stamp "boot: ssh up (+$((SECONDS - start))s)"

# shellcheck source=/dev/null
source "$DEPLOY_DIR/k8s-detect.sh"

section() { printf '\n=== %s ===\n' "$*"; }
section "bootc status";       vssh 'bootc status'
section "getenforce";         vssh 'getenforce'
section "insecure registry drop-ins"; vssh "grep -H -A2 '^\\[\\[registry\\]\\]' /etc/containers/registries.conf.d/*.conf" || true
section "image signature policy (bootc upgrade)"
vssh "grep -h '^container-image-reference' /ostree/deploy/*/deploy/*.origin | sort -u; \
      python3 -c 'import json;p=json.load(open(\"/etc/containers/policy.json\"));print(\"default:\",p[\"default\"]);[print(k,v) for k,v in p[\"transports\"][\"docker\"].items() if \"30080\" in k]' 2>/dev/null \
      || grep -A3 '30080' /etc/containers/policy.json; \
      sha256sum /etc/pki/containers/edge-cosign.pub" || true
section "$K8S service";       vssh "systemctl is-active $K8S_UNIT" || true

if (( WAIT_READY > 0 )); then
  log "waiting up to ${WAIT_READY}s for node Ready ($K8S)"
  t0=$SECONDS
  until vssh "$KUBECTL get nodes --no-headers 2>/dev/null | awk '\$2==\"Ready\"' | grep -q ."; do
    if (( SECONDS - t0 > WAIT_READY )); then
      log "node not Ready after ${WAIT_READY}s; collecting $K8S_UNIT journal"
      vssh "journalctl -u $K8S_UNIT -n 200 --no-pager" > "$STATE_DIR/$K8S_UNIT-journal.log" || true
      vssh "systemctl status $K8S_UNIT --no-pager" || true
      die "node not Ready; journal saved to $STATE_DIR/$K8S_UNIT-journal.log"
    fi
    sleep 30
  done
  stamp "boot: node Ready (+$((SECONDS - start))s since QEMU start)"
fi

section "kubectl get nodes -o wide"; vssh "$KUBECTL get nodes -o wide" || true
section "kubectl get pods -A";       vssh "$KUBECTL get pods -A -o wide" || true
