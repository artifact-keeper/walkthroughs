#!/usr/bin/env bash
# Run a command in the agent container, on the network the stack is on now (the site
# network after make disconnect).
#   agent/run.sh [-t TOKEN_NAME] [-h HOME_NAME] [-n NETWORK] [-e NAME] [-v SRC:DST] -- command [args...]
# TOKEN_NAME  a token from registry/.tokens/<name>.token, passed as AK_TOKEN and HF_TOKEN through
#             the environment only. Default: developer.
# HOME_NAME   a home under out/homes/<name> (default scratch, wiped first).
# The agent reaches Artifact Keeper as https://ak.internal and the model as
# http://ak-offgrid-llama:8080/v1. out/ is mounted at /out.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../registry/lib.sh"
load_env
home=scratch token=developer net="$NET" extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) token=$2; shift 2 ;;
    -h) home=$2; shift 2 ;;
    -n) net=$2; shift 2 ;;
    -e) extra+=(-e "$2"); shift 2 ;;
    -v) extra+=(-v "$2:z"); shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
H="$ROOT/out/homes/$home"
[[ "$home" == scratch ]] && rm -rf "$H"
mkdir -p "$H" "$ROOT/out"
AK_TOKEN="$(tok "$token")"; HF_TOKEN=$AK_TOKEN; export AK_TOKEN HF_TOKEN
exec podman run --rm -i --network "$net" --userns keep-id:uid=1000,gid=1000 \
  -e AK_TOKEN -e HF_TOKEN -e AK_URL="$AK_URL" -e LLM_URL="http://$PROJECT-llama:8080/v1" \
  -e HF_ENDPOINT="$AK_URL/huggingface/hf-models" "${extra[@]}" \
  -v "$H:/home/dev:z" -v "$ROOT/out:/out:z" -v "$HERE/agent.py:/opt/agent/agent.py:ro,z" \
  localhost/ak-offgrid/agent:latest "$@"
