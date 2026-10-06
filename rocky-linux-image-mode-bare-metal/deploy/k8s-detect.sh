# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this
# Sourced after ssh is up: sets K8S (rke2|k3s), K8S_UNIT, KUBECTL, CRICTL for the guest.
if vssh 'systemctl cat rke2-server.service >/dev/null 2>&1'; then
  K8S=rke2 K8S_UNIT=rke2-server
  KUBECTL='/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml'
  CRICTL='CONTAINER_RUNTIME_ENDPOINT=unix:///run/k3s/containerd/containerd.sock /var/lib/rancher/rke2/bin/crictl'
elif vssh 'systemctl cat k3s.service >/dev/null 2>&1'; then
  K8S=k3s K8S_UNIT=k3s
  KUBECTL='k3s kubectl'
  CRICTL='k3s crictl'
else
  K8S=none K8S_UNIT=none KUBECTL='kubectl' CRICTL='crictl'
  log "neither rke2-server nor k3s unit found in the guest"
fi
log "kubernetes distribution in guest: $K8S"
