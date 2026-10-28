#!/usr/bin/env bash
# Delete everything this walkthrough created (make clean): the ak-agent-* containers, the
# ak-agent_* volumes, the two networks, the sandbox image and the base images pulled
# through the registry, plus the generated secrets, tokens and state. Missing pieces are
# skipped; any other error stops the script. Images of the stack itself are kept.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
ROOT="$here/.."
port=30445; [[ -f "$ENV_FILE" ]] && { load_env; port=$HTTPS_PORT; }

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

"$ROOT/lab-upstream/down.sh"
if [[ -f "$ENV_FILE" ]]; then netns_retry compose --profile scanners down --volumes --remove-orphans; fi
ids=$(podman ps -aq --filter name='^ak-agent-')
[[ -z $ids ]] || netns_retry podman rm -f $ids >/dev/null
vols=$(podman volume ls -q --filter name='^ak-agent_')
[[ -z $vols ]] || podman volume rm -f $vols >/dev/null
for n in "$AGENT_NET" "$NET"; do
  if podman network exists "$n"; then podman network rm -f "$n" >/dev/null; fi
done
# By ID: base images pulled by digest have no tag, nor does a sandbox image a later build replaced.
imgs=$( { podman images -q --filter label=ak-agent=sandbox
          podman images --format '{{.ID}} {{.Repository}}' | awk -v p="localhost:$port/oci-" \
            '$2 == "localhost/ak-agent/sandbox" || index($2, p) == 1 {print $1}'; } | sort -u)
[[ -z $imgs ]] || podman rmi -f $imgs >/dev/null
rm -rf "$ENV_FILE" "$TOKENS" "$OUT" "$ROOT/out/gates" "$ROOT/agent/out" "$ROOT/app/.venv" \
       "$ROOT/app/node_modules" "$ROOT/internal/acme-agent-tools/dist"
echo "clean: removed containers, volumes, networks, the sandbox and proxied base images, and local state"
