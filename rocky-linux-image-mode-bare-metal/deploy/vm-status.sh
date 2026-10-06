#!/usr/bin/env bash
# One-screen summary: QEMU process, ssh reachability, booted image, k8s node.
source "$(dirname "$0")/lib.sh"
if ! vm_running; then echo "VM: not running (disk: $([[ -f $DISK ]] && echo present || echo none))"; exit 0; fi
echo "VM: running (pid $(vm_pid)), ssh -p $SSH_PORT root@localhost"
if ! vssh true 2>/dev/null; then echo "ssh: not reachable yet"; exit 0; fi
# shellcheck source=/dev/null
source "$DEPLOY_DIR/k8s-detect.sh" 2>/dev/null
vssh "bootc status --format=json" | jq -r '
  def img(x): if x then "\(x.image.version // "?")  \(x.image.image.image)@\(x.image.imageDigest)" else "-" end;
  "booted:   " + img(.status.booted),
  "staged:   " + img(.status.staged),
  "rollback: " + img(.status.rollback)'
echo "selinux:  $(vssh getenforce)"
echo "$K8S_UNIT: $(vssh "systemctl is-active $K8S_UNIT" || true)"
vssh "$KUBECTL get nodes --no-headers 2>/dev/null" || true
