#!/usr/bin/env bash
# G3 Disconnect: every Remote is cache-only, the scheduled upstream jobs are paused, every
# container of the stack is on the internal site network and nothing else, and the exported
# configuration says the site is offline.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_site
G=G3
AK_CONFIG_UPSTREAM_MODE_ISSUE=${AK_CONFIG_UPSTREAM_MODE_ISSUE:-"see findings"}
bad=""
for r in "${REMOTES[@]}"; do
  m=$(call admin GET "/api/v1/repositories/$r/upstream-mode" | jq -r '.effective_upstream_mode // .upstream_mode')
  echo "$r: $(jq -c . "$FOUT/.body")"
  [[ $m == cache_only ]] || bad+="$r=$m "
done
check $G "every Remote is cache-only (effective_upstream_mode, #5315)" "$bad" test -z "$bad"

api GET /admin/settings/system > "$GOUT/g3-settings.json"
jq -c '{upstream_jobs_paused, upstream_jobs_paused_source, upstream_jobs_paused_stored}' "$GOUT/g3-settings.json"
check $G "the scheduled upstream jobs are paused (upstream_jobs_paused, #5317)" "$(jq -c '{upstream_jobs_paused, upstream_jobs_paused_source}' "$GOUT/g3-settings.json")" \
  jq -e '.upstream_jobs_paused == true' "$GOUT/g3-settings.json"
podman logs --since "$(jq -r .at "$DISC")" "$PROJECT-backend" 2>&1 | grep -m1 'upstream_jobs_paused' | cut -c1-240

internal=$(podman network inspect "$SITE_NET" --format '{{.Internal}}' 2>/dev/null)
check $G "$SITE_NET is internal (no default route, no NAT; .1 is DNS only)" "internal=$internal" test "$internal" == true
podman network exists "$SEED_NET" && echo "$SEED_NET still exists; members: $(podman network inspect "$SEED_NET" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)"
off=""
for c in $(podman ps --format '{{.Names}}' | grep "^$PROJECT-"); do
  nets=$(podman inspect "$c" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | xargs)
  printf '  %-28s %s\n' "$c" "$nets"
  [[ $nets == "$SITE_NET" ]] || off+="$c($nets) "
done
check $G "every running container of the stack is on $SITE_NET only" "$off" test -z "$off"

j="$ROOT/out/config/site.json"
echo "exported Remotes: $(jq -c '[.repositories[] | select(.repo_type == "remote") | {key, upstream_mode}]' "$j")"
if jq -e '[.repositories[] | select(.repo_type == "remote")] | all(.upstream_mode == "cache_only")' "$j" >/dev/null; then
  pass $G "the exported configuration records every Remote as cache-only"
else
  blocked ak-gap $G "the exported configuration records every Remote as cache-only" \
    "config export has no upstream_mode, so the site's offline posture is not in its configuration of record ($AK_CONFIG_UPSTREAM_MODE_ISSUE)"
fi
