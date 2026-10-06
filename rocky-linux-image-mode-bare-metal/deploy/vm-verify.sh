#!/usr/bin/env bash
# Verify the sample workload runs and that its image came through Artifact Keeper:
#   - pod matching $WORKLOAD (default nginx) is Running
#   - registries.yaml / containerd mirror config points docker.io at 10.0.2.2:30080
#   - containerd log shows pulls from 10.0.2.2:30080
#   - Artifact Keeper's oci-dockerhub-proxy repo now holds the image
source "$(dirname "$0")/lib.sh"
WORKLOAD="${WORKLOAD:-nginx}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-900}"
PROXY_REPO="${PROXY_REPO:-oci-dockerhub-proxy}"
TOKEN_FILE="${TOKEN_FILE:-$REPO_ROOT/registry/.ak-token}"

vm_running || die "VM is not running"
wait_ssh 600 10
# shellcheck source=/dev/null
source "$DEPLOY_DIR/k8s-detect.sh"
section() { printf '\n=== %s ===\n' "$*"; }

log "waiting up to ${VERIFY_TIMEOUT}s until every pod matching '$WORKLOAD' is Running and Ready"
# All matching pods must be Running with READY n/n, so a rollout in progress
# (e.g. right after an upgrade re-seeds the manifests) is waited out.
settled="$KUBECTL get pods -A --no-headers 2>/dev/null | grep -E '$WORKLOAD' | awk '{split(\$3,r,\"/\"); if (\$4!=\"Running\" || r[1]!=r[2]) bad++; n++} END {exit !(n>0 && bad==0)}'"
t0=$SECONDS
# Right after a reboot the API still serves the previous boot's pod state; wait
# for the k8s service to finish starting so the manifests are re-applied first.
until vssh "systemctl is-active --quiet $K8S_UNIT" && vssh "$settled"; do
  if (( SECONDS - t0 > VERIFY_TIMEOUT )); then
    vssh "$KUBECTL get pods -A -o wide; $KUBECTL get events -A --sort-by=.lastTimestamp | tail -40" || true
    die "pods matching '$WORKLOAD' not all Running after ${VERIFY_TIMEOUT}s"
  fi
  sleep 20
done
stamp "verify: $WORKLOAD pod Running (+$((SECONDS - t0))s)"

section "kubectl get pods -A -o wide"; vssh "$KUBECTL get pods -A -o wide"
section "deployments matching $WORKLOAD (labels show the site-config release)"
vssh "$KUBECTL get deploy -A --show-labels | grep -E 'NAME|$WORKLOAD'" || true
section "workload image / imageID"
vssh "$KUBECTL get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{\"\\t\"}{.status.containerStatuses[*].image}{\"\\t\"}{.status.containerStatuses[*].imageID}{\"\\n\"}{end}'" \
  | grep -E "$WORKLOAD" | tee "$STATE_DIR/workload-images.tsv" || true
section "registries.yaml"
vssh "grep -v '^#' /etc/rancher/$K8S/registries.yaml" || true
section "containerd mirror config (hosts.toml)"
vssh "for f in /var/lib/rancher/$K8S/agent/etc/containerd/certs.d/*/hosts.toml; do echo \"# \$f\"; grep -v '^#' \"\$f\"; done" || true
section "crictl images"
vssh "$CRICTL images 2>/dev/null" || true
# containerd does not log which mirror endpoint served a pull; the timestamps here
# are matched against the created_at of the proxy's cached manifest below.
section "containerd log: $WORKLOAD pull"
vssh "grep -E 'PullImage|Pulled image' /var/lib/rancher/$K8S/agent/containerd/containerd.log | grep -E '$WORKLOAD' | cut -c1-330" || true

section "Artifact Keeper: $PROXY_REPO"
[[ -r "$TOKEN_FILE" ]] || die "no $TOKEN_FILE; cannot query the Artifact Keeper API"
listing="$(curl -fsS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  "http://$HOST_REGISTRY/api/v1/repositories/$PROXY_REPO/artifacts?per_page=500")"
echo "$listing" | jq -r '.items | "\(length) cached objects; images: \([.[].path | capture("^v2/(?<n>.+)/(manifests|blobs)/").n] | unique | join(", "))"'
echo "$listing" | jq -r --arg w "$WORKLOAD" '.items[] | select(.path | test($w)) | select(.path | test("/manifests/")) | [.path, .size_bytes, .download_count, .created_at] | @tsv' | column -t
fail=0
while IFS=$'\t' read -r pod image imageid; do
  digest="${imageid##*@}"
  if echo "$listing" | jq -e --arg d "$digest" '.items[] | select(.path | endswith("/manifests/" + $d))' >/dev/null; then
    log "OK: $pod runs $image @ $digest, and that manifest is cached in $PROXY_REPO"
  else
    log "FAIL: $pod digest $digest not found in $PROXY_REPO"; fail=1
  fi
done < "$STATE_DIR/workload-images.tsv"
(( fail == 0 )) || die "workload image did not come through Artifact Keeper"
stamp "verify: OK"
