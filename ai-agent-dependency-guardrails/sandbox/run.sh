#!/usr/bin/env bash
# Run a command in the agent sandbox, on agent-net (route to https://ak.internal only),
# with the agent's read-only token. The working directory is mounted at /home/agent/work.
#   sandbox/run.sh [-w DIR] -- CMD...      (DIR defaults to ../app)
# DIR is relabelled for the container on SELinux hosts (:z; a no-op elsewhere), so it must be
# a project or scratch directory (mktemp -d), never a system or home directory. Your user
# maps to the image's agent user (UID 1000), whatever your host UID is.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
work="$here/../app"
if [[ "${1:-}" == -w ]]; then work="$2"; shift 2; fi
[[ "${1:-}" == -- ]] && shift
work="$(cd "$work" && pwd -P)"
case "$work" in
  / | /tmp | /var/tmp | /dev/shm | /home | /root | /usr* | /etc* | /var | /opt | /srv | "$(cd ~ && pwd -P)")
    echo "sandbox/run.sh: refusing to mount $work (it would be relabelled); use a scratch dir from mktemp -d" >&2
    exit 2 ;;
esac
token="$(cat "$TOKENS/${SANDBOX_TOKEN:-agent}.token")"
exec podman run --rm -i --network "$AGENT_NET" --userns keep-id:uid=1000,gid=1000 \
  -e AK_TOKEN="$token" -e UV_INDEX_AK_PASSWORD="$token" \
  -v "$work:/home/agent/work:z" \
  localhost/ak-agent/sandbox:1 "$@"
