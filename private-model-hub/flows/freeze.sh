#!/usr/bin/env bash
# Step 7: freeze and go offline. The two Hub Remotes were frozen when bootstrap created them
# (cache-ttl 315360000 s, on-upstream-not-found keep): mutable paths such as revision/main
# never revalidate, and an upstream 404 never evicts a cached file. Seed the models the site
# needs while still connected, then disconnect and use them from a workstation on a network
# with no route out.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
repos=(hf-lab)
if hub_reachable; then repos+=(hf-hub); else echo "huggingface.co not reachable: hf-hub is left out"; fi
model_of() { [[ $1 == hf-hub ]] && echo "$HUB_MODEL" || echo "$LAB_MODEL"; }
args_of() { [[ $1 == hf-hub ]] && printf '%s\n' "${HUB_FILES[@]}"; true; }

say "the freeze, set at creation"
for r in "${repos[@]}"; do
  echo "$r: $(call admin GET "/api/v1/repositories/$r/cache-ttl" | jq -c .) $(call admin GET "/api/v1/repositories/$r/on-upstream-not-found" | jq -c .)"
done

say "seed: pull every model the site needs, the way it will be used"
for r in "${repos[@]}"; do
  m=$(model_of "$r"); mapfile -t a < <(args_of "$r")
  hf developer "$r" -h seed -- snapshot "$m" "${a[@]}" | jq -c '{ok, commit, files: (.files | length)}'
  hf developer "$r" -h seed -- encode "$m" | jq -c '{ok, shape}'
  hf developer "$r" -h seed -- automodel "$m" | jq -c '{ok, model, hidden}'
done

say "disconnect"
trap reconnect EXIT
disconnect
"$RUN" -o -- python -c '
import socket
for host in ("huggingface.co", "pypi.org", "1.1.1.1"):
    try:
        socket.create_connection((host, 443), timeout=5); print(host, "reachable")
    except OSError as e:
        print(host, "unreachable:", type(e).__name__, e)'

say "a workstation on the disconnected network fills its cache from Artifact Keeper and loads the models"
for r in "${repos[@]}"; do
  m=$(model_of "$r"); mapfile -t a < <(args_of "$r"); h="offline-$r"
  hf developer "$r" -o -h "$h" -- snapshot "$m" "${a[@]}" | tee "$FOUT/freeze-$r.json" | jq -c '{ok, commit, files: (.files | length), seconds}'
  sha=$(jq -r .commit "$FOUT/freeze-$r.json")
  call developer HEAD "$HFAPI/$r/$m/resolve/$sha/config.json" >/dev/null
  stale=$(hdr X-AK-Stale-Since || true)
  echo "$r HEAD resolve/${sha:0:12}.../config.json: HTTP $(code), X-AK-Stale-Since: ${stale:-absent}"
  # snapshot_download leaves out 1_Pooling/config.json (the tree listing is not recursive)
  hf developer "$r" -o -h "$h" -- download "$m" 1_Pooling/config.json --revision "$sha" | jq -c '{ok, seconds}'
  export HF_HUB_OFFLINE=1
  hf developer "$r" -o -h "$h" -e HF_HUB_OFFLINE -- encode "$m" | jq -c '{ok, shape, first, seconds}'
  hf developer "$r" -o -h "$h" -e HF_HUB_OFFLINE -- automodel "$m" | jq -c '{ok, model, hidden, seconds}'
  unset HF_HUB_OFFLINE
done

say "the same load without HF_HUB_OFFLINE, straight from Artifact Keeper (given 60 s)"
hf developer hf-lab -o -h offline-direct -- --timeout 60 encode "$LAB_MODEL" | jq -c '{ok, error, seconds}' || true
podman logs --since 70s "$PROJECT-backend" 2>&1 | grep -o 'method=HEAD uri=/huggingface/hf-lab/[^ ]*' | sed 's|.*/resolve/[0-9a-f]*/|resolve/<commit>/|' | sort | uniq -c | sort -rn | head -6

say "a model nobody seeded"
call developer GET "$HFAPI/hf-lab/acme-lab/never-seeded/resolve/main/config.json" >/dev/null
echo "GET acme-lab/never-seeded/resolve/main/config.json: HTTP $(code) $(head -c 80 "$FOUT/.body")"
