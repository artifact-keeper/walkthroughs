#!/usr/bin/env bash
# Delete everything this walkthrough created (make clean): the ak-agents-* containers, the
# ak-agents_* volumes, the network, the workstation image, and the generated secrets,
# tokens, homes and outputs. Kept: the stack's pulled images and the ak CLI build stage
# (localhost/ak-agents/ak-cli:*), so the next `make all` does not rebuild ak from source.
# Missing pieces are skipped; any other error stops the script.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"

# The last container to leave tears down podman's rootless network namespace. Where the
# pasta AppArmor profile refuses podman's SIGTERM (seen on Ubuntu 26.04), that fails with
# "rootless netns: kill network process: permission denied": on exactly that error, stop
# pasta ourselves and retry once. Any other error stops the script.
netns_retry() {
  local out rc=0 pidf pid
  out=$("$@" 2>&1) || rc=$?
  [[ -z $out ]] || printf '%s\n' "$out"
  (( rc == 0 )) && return 0
  grep -q 'rootless netns: kill network process: permission denied' <<<"$out" || return "$rc"
  pidf="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks/rootless-netns/rootless-netns-conn.pid"
  pid=$(cat "$pidf" 2>/dev/null || true)
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then kill "$pid"; fi
  echo "clean: stopped the rootless network helper (pasta) podman was not allowed to stop; retrying"
  "$@"
}

if [[ -f "$ENV_FILE" ]]; then netns_retry compose --profile scanners down --volumes --remove-orphans; fi
ids=$(podman ps -aq --filter name="^$PROJECT-")
[[ -z $ids ]] || netns_retry podman rm -f $ids >/dev/null
vols=$(podman volume ls -q --filter name="^${PROJECT}_")
[[ -z $vols ]] || podman volume rm -f $vols >/dev/null
if podman network exists "$NET"; then podman network rm -f "$NET" >/dev/null; fi
if podman image exists localhost/ak-agents/workstation:latest; then
  podman rmi -f localhost/ak-agents/workstation:latest >/dev/null
fi
# out/homes holds files written by containers; remove them through a container in case
# any are not owned by this user on the host.
if [[ -d "$ROOT/out/homes" ]]; then
  podman run --rm -v "$ROOT/out:/out:z" docker.io/library/alpine:3.24 rm -rf /out/homes >/dev/null 2>&1 || true
fi
rm -rf "$ENV_FILE" "$TOKENS" "$OUT" "$ROOT/out" "$ROOT/client/.work"
echo "clean: removed containers, volumes, the network, the workstation image and local state"
