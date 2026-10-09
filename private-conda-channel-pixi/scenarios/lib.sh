# shellcheck shell=bash
# Helpers for the scenario scripts. Source it; do not run it.
# Reuses registry/lib.sh (load_env, akcurl, AK_HOST_URL, admin_token, TOKENS, CA, NET).
SCN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCN_DIR/.." && pwd)"
source "$ROOT/registry/lib.sh"; load_env
WORK="$SCN_DIR/.work"; mkdir -p "$WORK"
# Scenario secrets live in scenarios/.env (never committed; the ak-conda
# registry/.env is only read): SCN_NEXUS_ADMIN_PASSWORD, PROGET_API_KEY
SCN_ENV="$SCN_DIR/.env"
[[ -f "$SCN_ENV" ]] && { set -a; source "$SCN_ENV"; set +a; }
ensure_secret() { # NAME: generate once, then export
  local n=$1
  grep -qs "^$n=" "$SCN_ENV" || { (umask 077; echo "$n=Sc$(openssl rand -hex 12)" >> "$SCN_ENV"); }
  set -a; source "$SCN_ENV"; set +a
}
log() { echo "$(basename "$0" .sh): $*"; }
# Wait until URL answers 200; prints seconds waited.
wait_http() { # URL TIMEOUT_S
  local t0=$SECONDS
  until curl -fsS -o /dev/null "$1" 2>/dev/null; do
    (( SECONDS - t0 > $2 )) && { echo "timeout waiting for $1" >&2; return 1; }; sleep 2; done
  echo $((SECONDS - t0))
}
# The consumer token, as upstream credentials for the product's proxy.
consumer_token() { cat "$TOKENS/consumer.token"; }

# ---------------------------------------------------------------------------
# Scenario suite (S1..S7). Each scenario script:
#   scn_begin S1 behind-nexus "what it proves"     # log, header, EXIT trap
#   on_exit 'restore command'                      # run in reverse order at exit, also on failure
#   pass/fail/blocked "check" ["why"]              # the gates' verdict format
#   ev "evidence line"                             # printed now and again in the evidence block
# Output is teed to $SCN_OUT/<id>-<name>.log; verdicts accumulate in $SCN_OUT/results.tsv.
# Big files (repodata downloads, pixi outputs) go under $SCN_OUT too.
SCN_OUT="${SCN_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/ak-scenarios}"; mkdir -p "$SCN_OUT"
SCN_RESULTS="$SCN_OUT/results.tsv"
CLIENT=localhost/ak-conda/pixi-client:0.81.0
U=$(AK_HOST_URL)
NX="http://127.0.0.1:${NEXUS_PORT:-30481}"; NXR="$NX/repository"
NX_IN=http://scn-nexus:8081                      # Nexus as clients on ak-conda-net see it
SCN_TOKENS="$SCN_DIR/.tokens"; mkdir -p "$SCN_TOKENS"; chmod 700 "$SCN_TOKENS"
OUTSIDE="${OUTSIDE:-colorama}"                   # on conda-forge, not in project/pixi.lock
OUTSIDE_FILE="${OUTSIDE_FILE:-noarch/colorama-0.4.6-pyhd8ed1ab_1.conda}"
EVIDENCE=(); RESTORE=(); SID=""

AM=${AM:-nexus}                                  # the artifact manager in front: nexus | proget
AM_TAG=$([[ $AM == nexus ]] || echo "[$AM] ")    # prefixed to every check of a non-Nexus run
verdict() { # STATUS CHECK [WHY]
  local line; line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "$1" "$SID" "$AM_TAG$2" "${3:-}")
  echo "$line" >> "$SCN_RESULTS"
  printf '%-12s %-4s %s%s\n' "$1" "$SID" "$AM_TAG$2" "${3:+: $3}"
}
pass()    { verdict PASS "$@"; }
fail()    { verdict FAIL "$@"; SCN_FAILED=1; }
blocked() { local f=$1; shift; verdict "BLOCKED($f)" "$@"; }
check()   { # COND-EXIT-CODE CHECK [WHY-IF-FAIL]: pass if $1 == 0
  if [[ $1 == 0 ]]; then pass "$2"; else fail "$2" "${3:-}"; fi; }
ev() { EVIDENCE+=("$*"); echo "  > $*"; }
on_exit() { RESTORE+=("$1"); }
# Restore journal for the changes to ak-conda that must never outlive a run (allowlist, the
# conda-forge upstream URL and scan config, a stopped backend). The EXIT trap covers normal
# exits, failures, INT, TERM and HUP; SIGKILL (a killed session) cannot be trapped, so guard
# also writes the restore command to $WORK/pending/<key>.sh before the change. The next
# scenario (scn_begin) or `make scenarios-restore` replays what a killed run left there.
# The command runs in a fresh shell with lib.sh loaded: literal values only, no script variables.
PENDING="$WORK/pending"; mkdir -p "$PENDING"
guard() { # KEY COMMAND: on_exit COMMAND, journalled until it has run
  [[ -f "$PENDING/$1.sh" ]] || printf '# %s %s %s\n%s\n' "$(date -u +%FT%TZ)" "$SID" "$1" "$2" > "$PENDING/$1.sh"
  on_exit "$2; rm -f '$PENDING/$1.sh'"; }
replay_pending() {
  local f; for f in "$PENDING"/*.sh; do [[ -f $f ]] || continue
    echo "-- replaying the restore of a run that was killed before its trap ($(head -1 "$f" | cut -c3-)):"
    ( set +e; eval "$(tail -n +2 "$f")" ) && rm -f "$f"; done; }
note() { echo "-- $*"; }

scn_begin() { # ID NAME DESCRIPTION
  SID=$1; SNAME=$2; SLOG="$SCN_OUT/$1-$2.log"; SCN_FAILED=0
  exec 3>&1 4>&2
  exec > >(tee "$SLOG") 2>&1; TEE_PID=$!
  trap scn_exit EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  replay_pending
  echo "=== $SID $SNAME: $3"
  echo "    $(date -u +%FT%TZ); backend $(podman inspect ak-conda-backend --format '{{.ImageName}}' 2>/dev/null);" \
       "$AM $(podman inspect "scn-$AM" --format '{{.ImageName}}' 2>/dev/null); log $SLOG"
  SCN_T0=$SECONDS
}
scn_exit() {
  local rc=$? i
  (( SCN_FAILED )) && rc=1
  if ((${#RESTORE[@]})); then
    echo "-- restore"
    for ((i=${#RESTORE[@]}-1; i>=0; i--)); do eval "${RESTORE[$i]}" || echo "   restore step failed: ${RESTORE[$i]}"; done
  fi
  echo "--- $SID evidence"
  for i in "${EVIDENCE[@]}"; do echo "  $i"; done
  echo "--- $SID done in $((SECONDS - SCN_T0)) s (exit $rc), log $SLOG"
  exec 1>&3 2>&4; wait "$TEE_PID" 2>/dev/null
  exit "$rc"
}

# --- Artifact Keeper --------------------------------------------------------
adm() { echo "Authorization: Bearer $(admin_token)"; }
akapi() { # METHOD PATH [curl args]: admin API call, body on stdout
  akcurl -sS -X "$1" -H "$(adm)" -H 'Content-Type: application/json' "$U/api/v1$2" "${@:3}"; }
# akget TOKEN-FILE PATH [curl args] -> "<code> <bytes> <seconds>", body in $WORK/last.body
akget() { local t=$1 p=$2; shift 2
  akcurl -sS -o "$WORK/last.body" -w '%{http_code} %{size_download} %{time_total}' -H "Authorization: Bearer $(<"$t")" "$@" "$U/$p"; }
consumer_tok() { echo "$TOKENS/consumer.token"; }
backend_health() { podman inspect ak-conda-backend --format '{{.State.Health.Status}}' 2>/dev/null || echo absent; }
wait_backend_healthy() { # TIMEOUT_S -> prints seconds
  local t0=$SECONDS
  until [[ $(backend_health) == healthy ]]; do (( SECONDS - t0 > $1 )) && break; sleep 2; done; echo $((SECONDS - t0)); }
# Caddy access log since a unix time: bytes ak.internal served, grouped by user agent
# family and status. Optional URI regex filter.
ak_served_since() { # UNIX_T [URI_REGEX]
  podman logs --since "$(date -u -d "@$1" +%FT%TZ)" ak-conda-caddy 2>&1 | grep '"uri"' |
    jq -r --argjson t "$1" --arg re "${2:-.}" 'select(.ts >= $t and (.request.uri | test($re))) |
      [((.request.headers["User-Agent"] // ["-"])[0] | split("/")[0] | split(" ")[0]), .status, .size] | @tsv' |
    awk -F'\t' '{k=$1" "$2; n[k]++; b[k]+=$3; tb+=$3; tn++} END {for (k in n) printf "%s x%d %.1fMB; ", k, n[k], b[k]/1e6; printf "total %d req %.1f MB\n", tn, tb/1e6}'
}
ak_bytes_since() { # UNIX_T UA_PREFIX -> bytes
  podman logs --since "$(date -u -d "@$1" +%FT%TZ)" ak-conda-caddy 2>&1 | grep '"uri"' |
    jq -r --argjson t "$1" --arg ua "$2" 'select(.ts >= $t and (((.request.headers["User-Agent"] // ["-"])[0]) | startswith($ua))) | .size' |
    awk '{b+=$1} END {print b+0}'
}

# Allowlist on conda-virtual: save now, restore exactly at exit.
al_save() {
  local c; c=$(akcurl -sS -o "$WORK/allowlist.$SID.json" -w '%{http_code}' -H "$(adm)" "$U/api/v1/repositories/conda-virtual/allowlist")
  [[ $c == 200 ]] || echo '{"absent":true}' > "$WORK/allowlist.$SID.json"
  ev "allowlist before: $(jq -c '{enabled, entry_count, absent}' "$WORK/allowlist.$SID.json")"
  [[ -f "$PENDING/allowlist.sh" ]] || cp "$WORK/allowlist.$SID.json" "$PENDING/allowlist.json"
  guard allowlist "al_restore '$PENDING/allowlist.json'"
}
al_restore() { # [SAVED-FILE]
  local f="${1:-$WORK/allowlist.$SID.json}" c
  if jq -e .absent "$f" >/dev/null 2>&1; then c=$(akapi DELETE /repositories/conda-virtual/allowlist -o /dev/null -w '%{http_code}')
  else c=$(akapi PUT /repositories/conda-virtual/allowlist -o /dev/null -w '%{http_code}' -d "$(jq -c '{enabled, entries: (.entries // [])}' "$f")"); fi
  echo "   allowlist restored: HTTP $c, now $(akapi GET /repositories/conda-virtual/allowlist | jq -c '{enabled, entry_count}')"
}
# conda-forge remote upstream URL back to URL (S2's restore)
forge_upstream_restore() { # URL
  echo "   PATCH upstream_url back: HTTP $(akapi PATCH /repositories/conda-forge -o /dev/null -w '%{http_code}' -d "$(jq -nc --arg u "$1" '{upstream_url:$u}')"), now $(akapi GET /repositories/conda-forge | jq -r .upstream_url)"; }
# conda-forge scan configuration back to the JSON config read before (S5's restore; "null": all off)
scan_cfg_restore() { # CONFIG-JSON
  local body
  if [[ $1 == null ]]; then body='{"scan_enabled":false,"scan_on_upload":false,"scan_on_proxy":false,"block_on_policy_violation":false,"proxy_scan_action":"fail_open"}'
  else body=$(jq -c '{scan_enabled, scan_on_upload, scan_on_proxy, block_on_policy_violation, severity_threshold, proxy_scan_action} | with_entries(select(.value != null))' <<<"$1"); fi
  echo "   conda-forge scan config restored: HTTP $(akapi PUT /repositories/conda-forge/security -o /dev/null -w '%{http_code}' -d "$body"), now $(akapi GET /repositories/conda-forge/security | jq -c '.config | {scan_enabled, scan_on_proxy, proxy_scan_action, block_on_policy_violation}'); dashboard policy_violations_blocked $(akapi GET /security/dashboard | jq .policy_violations_blocked)"; }
al_on_from_lock() { "$ROOT/allowlist/from-lock.sh" "${1:-$ROOT/project/pixi.lock}" | tail -1; }
al_off() { "$ROOT/allowlist/off.sh" | tail -1; }

# --- Nexus ------------------------------------------------------------------
nxapi() { curl -sS -u "admin:$SCN_NEXUS_ADMIN_PASSWORD" -X "$1" -H 'Content-Type: application/json' "$NX/service/rest$2" "${@:3}"; }
nx_invalidate() { echo "invalidate-cache $1: HTTP $(nxapi POST "/v1/repositories/$1/invalidate-cache" -o /dev/null -w '%{http_code}')"; }
# Delete a proxy's cached assets whose path matches REGEX (makes "never fetched" true again).
nx_purge() { # REPO REGEX -> number deleted
  local repo=$1 re=$2 tok="" page ids=() n=0 id
  while :; do
    page=$(nxapi GET "/v1/assets?repository=$repo${tok:+&continuationToken=$tok}")
    mapfile -t -O "${#ids[@]}" ids < <(jq -r --arg re "$re" '.items[] | select(.path | test($re)) | .id' <<<"$page")
    tok=$(jq -r '.continuationToken // empty' <<<"$page"); [[ -n $tok ]] || break
  done
  for id in "${ids[@]}"; do [[ -n $id ]] && nxapi DELETE "/v1/assets/$id" -o /dev/null && n=$((n + 1)); done
  echo "$n"
}
nx_has() { nxapi GET "/v1/search/assets?repository=$1&q=$2" | jq -r --arg p "$3" '[.items[] | select(.path == $p)] | length'; }
# nxget REPO PATH [curl args] -> "<code> <bytes> <seconds>", body in $WORK/last.body
nxget() { local r=$1 p=$2; shift 2; curl -sS -o "$WORK/last.body" -w '%{http_code} %{size_download} %{time_total}' "$@" "$NXR/$r/$p"; }
nx_mark() { podman exec scn-nexus sh -c 'wc -l < /nexus-data/log/request.log'; }
nx_served_since() { # MARK -> what Nexus served to clients under /repository/
  podman exec scn-nexus tail -n +$(($1 + 1)) /nexus-data/log/request.log |
    awk '$7 ~ /^\/repository\// { n[$9]++; b[$9]+=($11 == "-" ? 0 : $11); tb+=($11 == "-" ? 0 : $11); tn++ }
      END { for (s in n) printf "HTTP %s x%d %.1fMB; ", s, n[s], b[s]/1e6; printf "total %d req %.1f MB\n", tn, tb/1e6 }'
}
nx_bytes_since() { podman exec scn-nexus tail -n +$(($1 + 1)) /nexus-data/log/request.log | awk '$7 ~ /^\/repository\// {b+=($11 == "-" ? 0 : $11)} END {print b+0}'; }

# --- ProGet -----------------------------------------------------------------
PG="http://127.0.0.1:${PROGET_PORT:-30482}"; PGF="$PG/conda"
PG_IN=http://scn-proget                          # ProGet as clients on ak-conda-net see it
PG_PY=${PROGET_PY:-python3}                      # a python with playwright (proget/ui.py)
pgapi() { curl -sS -H "X-ApiKey: $PROGET_API_KEY" -H 'Content-Type: application/json' -X "$1" "$PG/api/management$2" "${@:3}"; }
# pgget FEED PATH [curl args] -> "<code> <bytes> <seconds>", body in $WORK/last.body
pgget() { local f=$1 p=$2; shift 2; curl -sS --max-time 900 -o "$WORK/last.body" -w '%{http_code} %{size_download} %{time_total}' "$@" "$PGF/$f/$p"; }
pgui() { PROGET_URL=$PG "$PG_PY" "$SCN_DIR/proget/ui.py" "$@"; }
# A feed over existing connectors (a fresh feed has an empty package cache; the connector's
# index is shared). Removed at exit.
pg_feed() { # NAME CONNECTOR...
  local n=$1; shift
  pgapi DELETE "/feeds/delete/$n" -o /dev/null 2>&1
  local c; c=$(pgapi POST /feeds/create -o /dev/null -w '%{http_code}' -d "$(jq -nc --arg n "$n" '{name:$n, feedType:"conda", active:true, connectors:$ARGS.positional}' --args "$@")")
  [[ $c == 201 ]] || { echo "pg_feed $n: HTTP $c" >&2; return 1; }
  on_exit "pg_feed_rm $n"
}
pg_feed_rm() { echo "   feed $1 deleted: HTTP $(pgapi DELETE "/feeds/delete/$1" -o /dev/null -w '%{http_code}')"; }
# A connector (and its own, empty, local index). Removed at exit.
pg_connector() { # NAME URL [TOKEN-FILE]
  pgapi POST "/connectors/delete/$1" -o /dev/null 2>&1
  local c; c=$(pgapi POST /connectors/create -o /dev/null -w '%{http_code}' -d "$(jq -nc --arg n "$1" --arg u "$2" --arg t "$([[ -n ${3:-} ]] && cat "$3")" \
    '{name:$n, url:$u, feedType:"conda", timeout:600} + (if $t != "" then {username:"consumer", password:$t} else {} end)')")
  [[ $c == 201 ]] || { echo "pg_connector $1: HTTP $c" >&2; return 1; }
  on_exit "pg_connector_rm $1"
}
# Deleting a connector leaves its index directory (1.6 GB for an AK-sized channel); remove it too.
pg_connector_rm() {
  local id; id=$(pg_id "$1"); rm -f "$WORK/proget-connector-ids.tsv"
  echo "   connector $1 deleted: HTTP $(pgapi POST "/connectors/delete/$1" -o /dev/null -w '%{http_code}')$([[ -n $id ]] && podman exec scn-proget rm -rf "/usr/share/ProGet/LocalStorage/Connectors/C$id" && echo ", index directory C$id removed")"; }
# Connector name -> id (C<id> is its local index directory); the API does not return ids, the UI does.
pg_id() { # CONNECTOR
  local f="$WORK/proget-connector-ids.tsv" id
  id=$(awk -F'\t' -v n="$1" '$1 == n {print $2}' "$f" 2>/dev/null)
  [[ -n $id ]] || { pgui ids > "$f"; id=$(awk -F'\t' -v n="$1" '$1 == n {print $2}' "$f"); }
  echo "$id"; }
pg_index_file() { echo "/usr/share/ProGet/LocalStorage/Connectors/C$(pg_id "$1")/index.sqlite3"; }
# The connector's local index file: "<bytes> <mtime unix>" (0 0 when absent)
pg_index() { podman exec scn-proget sh -c "stat -c '%s %Y' $(pg_index_file "$1") 2>/dev/null || echo '0 0'"; }
# Seconds since the connector's index file was last written (ProGet starts an update on a client
# request once its own record of the last update is about 10 minutes old; see README)
pg_index_age() { echo $(( $(date +%s) - $(pg_index "$1" | cut -d' ' -f2) )); }
# What ProGet fetched from ak.internal since a unix time (Caddy log, user agent ProGet/...)
pg_upstream_since() { # UNIX_T [URI_REGEX]
  podman logs --since "$(date -u -d "@$1" +%FT%TZ)" ak-conda-caddy 2>&1 | grep '"uri"' |
    jq -r --argjson t "$1" --arg re "${2:-.}" 'select(.ts >= $t and ((.request.headers["User-Agent"] // [""])[0] | startswith("ProGet")) and (.request.uri | test($re)))
      | "\(.request.uri | sub("^/conda/"; "") | sub("/[^/]*\\.(conda|tar\\.bz2)$"; "/<pkg>")) \(.status)\((.request.headers["If-Modified-Since"] // [])[0] | if . then " IMS" else "" end)"' |
    sort | uniq -c | awk '{printf "%s %s%s x%d; ", $2, $3, ($4 ? " " $4 : ""), $1}'; echo; }
# What scn-proget served under /conda/ since a unix time (its request log): "HTTP <code> x<n> <MB>; ..."
pg_served_since() { # UNIX_T
  podman logs --since "$(date -u -d "@$1" +%FT%TZ)" scn-proget 2>&1 | grep -E 'Request finished HTTP/1.1 GET http://[^ ]*/conda/' |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "-") { c = $(i + 1); b = $(i + 2); break }
           n[c]++; s[c] += (b ~ /^[0-9]+$/ ? b : 0); tn++; tb += (b ~ /^[0-9]+$/ ? b : 0) }
         END { for (k in n) printf "HTTP %s x%d %.1fMB; ", k, n[k], s[k] / 1e6; printf "total %d req %.1f MB\n", tn, tb / 1e6 }'; }
pg_bytes_since() { podman logs --since "$(date -u -d "@$1" +%FT%TZ)" scn-proget 2>&1 | grep -E 'Request finished HTTP/1.1 GET http://[^ ]*/conda/' |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "-") { b = $(i + 2); break } t += (b ~ /^[0-9]+$/ ? b : 0) } END { print t + 0 }'; }
# A pixi config whose conda channels go to the given ProGet feeds
pg_config() { # VIRTUAL-FEED [INTERNAL-FEED] -> path
  local f="$WORK/pixi-config-pg-$1.toml"
  printf 'tls-root-certs = "system"\n\n[mirrors]\n"https://ak.internal/conda/conda-virtual" = ["%s/conda/%s"]\n"https://ak.internal/conda/conda-internal" = ["%s/conda/%s"]\n"https://ak.internal/conda/scn-virtual" = ["%s/conda/ak-scn-virtual"]\n\n[pypi-config]\nindex-url = "https://ak.internal/pypi/pypi-remote/simple"\n' \
    "$PG_IN" "$1" "$PG_IN" "${2:-ak-internal}" "$PG_IN" > "$f"
  echo "$f"; }
# Force a connector's index update the way ProGet's UI offers it (Local Index > delete), then
# wait until FEED serves a non-empty noarch index built after the delete. Prints
# "<seconds> s, <records> noarch records, upstream: <what ProGet fetched>"; rc 1 on timeout.
# While the index is rebuilt ProGet answers metadata requests with an EMPTY index (HTTP 200).
pg_reindex() { # CONNECTOR FEED [TIMEOUT_S]
  local t0=$SECONDS tu n=0 r empty=""; tu=$(date +%s)
  pgui delete-index "$1" >/dev/null
  while (( SECONDS - t0 < ${3:-1500} )); do
    r=$(pgget "$2" noarch/repodata.json); n=$(recs_all < "$WORK/last.body" 2>/dev/null)
    [[ ${r%% *} == 200 && ${n:-0} == 0 && -z $empty ]] && empty="first answer after the delete: HTTP ${r%% *} with 0 records ($(awk '{print $2}' <<<"$r") bytes); "
    (( ${n:-0} > 0 && $(pg_index "$1" | cut -d' ' -f2) >= tu )) && { echo "$((SECONDS - t0)) s, $n noarch records; ${empty}upstream: $(pg_upstream_since "$tu" 'json')"; return 0; }
    sleep 10
  done; echo "timeout after $((SECONDS - t0)) s; ${empty}"; return 1; }
# Wait until CONNECTOR has a local index and FEED serves records (the first metadata request
# starts the index build; until it is done ProGet answers with an empty index).
pg_warm() { # CONNECTOR FEED [TIMEOUT_S] -> "<seconds> s, <records> records, index <MB>"
  local t0=$SECONDS r n=0
  while (( SECONDS - t0 < ${3:-1800} )); do
    r=$(pgget "$2" noarch/repodata.json); n=$(recs_all < "$WORK/last.body" 2>/dev/null)
    (( ${n:-0} > 0 )) && { echo "$((SECONDS - t0)) s, $n noarch records, index $(pg_index "$1" | awk '{printf "%.0f MB", $1/1e6}')"; return 0; }
    sleep 15
  done; echo "timeout after $((SECONDS - t0)) s"; return 1; }
# Poll FEED's noarch index (an ordinary client GET every 30 s, which is also what makes ProGet
# start its update) until NAME is present/absent. Prints seconds; rc 1 after MAX_S.
pg_wait_listing() { # FEED NAME present|absent [MAX_S]
  local t0=$SECONDS n
  while (( SECONDS - t0 < ${4:-${PG_PROPAGATION_MAX_S:-2400}} )); do
    pgget "$1" noarch/repodata.json >/dev/null; n=$(recs "$2" < "$WORK/last.body" 2>/dev/null)
    if [[ -n $n ]] && { [[ $3 == present && $n -gt 0 ]] || [[ $3 == absent && $n == 0 && $(recs_all < "$WORK/last.body") -gt 0 ]]; }; then
      echo $((SECONDS - t0)); return 0; fi
    sleep 30
  done; echo $((SECONDS - t0)); return 1; }
recs_all() { jq '(.["packages.conda"] // {} | length) + (.packages // {} | length)'; }
# Records of NAME in a repodata.json on stdin
recs() { jq --arg n "$1" '[(.["packages.conda"] // {}), (.packages // {}) | .[] | select(.name == $n)] | length'; }

# --- pixi -------------------------------------------------------------------
# px VIA DIR VOLUME pixi-args...   VIA: ak (image config: straight to ak.internal),
#   nexus (scenarios/nexus/pixi-config.toml), or a path to a pixi config.toml.
# Sets PX_RC, PX_S (seconds), PX_OUT (output file, WARN lines dropped). VOLUME "new:<name>" starts cold.
px() {
  local via=$1 dir; dir=$(cd "$2" && pwd); local vol=$3; shift 3
  local cfg=() auth="${PX_AUTH:-$TOKENS/consumer-auth.json}"
  case $via in ak) ;; nexus|proget) cfg=(-v "$SCN_DIR/$via/pixi-config.toml:/etc/pixi/config.toml:ro,z") ;;
    *) cfg=(-v "$via:/etc/pixi/config.toml:ro,z") ;; esac
  [[ $vol == new:* ]] && { vol=${vol#new:}; podman volume rm -f "$vol" >/dev/null 2>&1; }
  PX_OUT="$SCN_OUT/$SID-px-$(date +%s%N).out"
  local s0; s0=$(date +%s.%N)
  podman run --rm --network "${NETWORK:-$NET}" -v "$vol:/cache" -v "$dir:/work:z" -w /work "${cfg[@]}" \
    -v "$auth:/run/secrets/rattler-auth.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
    "$CLIENT" pixi "$@" > "$PX_OUT.raw" 2>&1; PX_RC=$?
  PX_S=$(echo "$(date +%s.%N) - $s0" | bc | xargs printf '%.1f')
  grep -v '^ WARN' "$PX_OUT.raw" > "$PX_OUT"; rm -f "$PX_OUT.raw"
}
# The solver's message, flattened: "No candidates were found for colorama *" etc.
px_msg() { # the most specific message first
  local flat re m; flat=$(tr -s ' \n│╰─▶├×' ' ' < "$PX_OUT")
  flat=${flat//ak.internal\/ /ak.internal/}
  for re in "No candidates were found for [^.]*" "hash mismatch[^,]*expected [0-9a-f]+, got [0-9a-f]+" "HTTP status [^)]*\) for url \([^)]*\)" \
            "Request failed after [^.]*" "Remote Auto Blocked[^.]*" "Error: .{0,240}"; do
    m=$(grep -oE "$re" <<<"$flat" | head -1); [[ -n $m ]] && { echo "$m"; return; }
  done; }
px_tail() { tail -"${1:-3}" "$PX_OUT" | tr -s ' \n' ' '; }
lock_has() { grep -m1 -oE "^- conda: [^ ]*/$2-[0-9][^ ]*" "$1/pixi.lock" 2>/dev/null | cut -c10-; }
lock_version() { lock_has "$1" "$2" | sed -E "s|.*/$2-([^-]+)-[^-]+$|\1|"; }
# A scenario copy of project/: DIR [conda-only]
project_copy() {
  rm -rf "$1"; mkdir -p "$1"
  if [[ ${2:-} == conda-only ]]; then
    [[ -f "$WORK/conda-only/pixi.lock" ]] || { echo "project_copy: $WORK/conda-only/pixi.lock missing (scenarios/up.sh makes it)" >&2; return 1; }
    cp "$WORK/conda-only/pixi.toml" "$WORK/conda-only/pixi.lock" "$1/"
  else cp "$ROOT/project/pixi.toml" "$ROOT/project/pixi.lock" "$1/"; fi
}
# A pixi config whose only conda channel is a Nexus group (base_url workaround, see README 5)
group_config() { # GROUP -> path
  local f="$WORK/pixi-config-$1.toml"
  printf 'tls-root-certs = "system"\n\n[mirrors]\n"%s/conda/conda-virtual" = ["%s/repository/%s"]\n' "$NX_IN" "$NX_IN" "$1" > "$f"
  echo "$f"
}
sha() { sha256sum "$1" | cut -c1-16; }
# A small conda-forge noarch file that neither Artifact Keeper's conda-forge proxy nor
# Nexus's ak-virtual has ever cached (AK: proxy-scans?path= is 404; Nexus: no asset).
# Call while conda-forge is reachable. Prints "noarch/<file>".
pick_uncached() {
  local list="$SCN_OUT/cf-noarch-small.txt" f
  if [[ ! -s $list || -n $(find "$list" -mmin +1440 2>/dev/null) ]]; then
    akget "$(consumer_tok)" conda/conda-forge/noarch/repodata.json.zst >/dev/null
    zstd -dqc "$WORK/last.body" | jq -r '.["packages.conda"] | to_entries[] | select(.value.size < 60000) | .key' > "$list"
  fi
  for f in $(shuf -n 40 "$list"); do
    [[ $(akapi GET "/repositories/conda-forge/security/proxy-scans?path=noarch/$f" -o /dev/null -w '%{http_code}') == 404 ]] || continue
    [[ $AM != nexus || $(nx_has ak-virtual "${f%%-[0-9]*}" "/noarch/$f") == 0 ]] || continue   # ProGet fetches only through AK
    echo "noarch/$f"; return 0
  done; return 1
}

# The gate's fake upstream (gates/fake-upstream.sh, http://fake-upstream:8000, AK remote
# conda-fake-upstream): the one private host this stack lets Artifact Keeper proxy (SSRF
# guard). Scenarios patch its repodata (json and zst) for a run and restore it at exit.
FU="$ROOT/out/fake-upstream"; FU_ADDED=()
fu_patch() { # SUBDIR JQ_FILTER [jq args...]
  local sub=$1 f=$2; shift 2; local d="$FU/$sub"
  [[ -f "$d/.scn-orig.json" ]] || { cp -p "$d/repodata.json" "$d/.scn-orig.json"; cp -p "$d/repodata.json.zst" "$d/.scn-orig.json.zst"; }
  [[ " ${FU_PATCHED:-} " == *" $sub "* ]] || { FU_PATCHED="${FU_PATCHED:-} $sub"; on_exit "fu_restore $sub"; }
  jq -c "$@" "$f" "$d/.scn-orig.json" > "$d/.scn-new.json" && mv "$d/.scn-new.json" "$d/repodata.json" &&
    zstd -qf -19 "$d/repodata.json" -o "$d/repodata.json.zst"
}
fu_add_file() { cp "$1" "$FU/$2"; FU_ADDED+=("$FU/$2"); }
fu_restore() {
  local d="$FU/$1"
  [[ -f "$d/.scn-orig.json" ]] && mv "$d/.scn-orig.json" "$d/repodata.json" && mv "$d/.scn-orig.json.zst" "$d/repodata.json.zst"
  ((${#FU_ADDED[@]})) && rm -f "${FU_ADDED[@]}"
  echo "   fake upstream $1/repodata.json restored ($(sha256sum < "$d/repodata.json" | cut -c1-12))"
}
# ProGet's conda connector reads channeldata.json first, and Artifact Keeper's virtual channel
# answers channeldata.json with 502 when any member has none ("member 'conda-fake-upstream'
# failed: no candidate document available upstream"); the gate's fake upstream has none. For
# a ProGet run over scn-virtual, give it one (removed at exit) and wait until scn-virtual serves.
# Call it directly, not in $(...): the removal is registered with on_exit.
fu_channeldata() {
  local f="$FU/channeldata.json" t0=$SECONDS
  [[ -f $f ]] || { jq -n '{channeldata_version: 1, subdirs: ["linux-64", "noarch"], packages: {"acme-core": {subdirs: ["noarch"], version: "99.0.0"}}}' > "$f"
    on_exit "rm -f '$f'; echo '   fake upstream channeldata.json removed'"; }
  while (( SECONDS - t0 < 180 )); do
    [[ $(akget "$SCN_TOKENS/scn-reader.token" conda/scn-virtual/channeldata.json | cut -d' ' -f1) == 200 ]] && { echo "scn-virtual channeldata.json 200 after $((SECONDS - t0)) s"; return 0; }
    sleep 5; done; echo "scn-virtual channeldata.json still $(head -c 160 "$WORK/last.body")"; return 1; }
# Wait until Artifact Keeper's conda-fake-upstream remote serves what the predicate (jq -e) says.
fu_wait() { # SUBDIR JQ_PREDICATE TIMEOUT_S -> seconds waited, rc 1 on timeout
  local t0=$SECONDS
  while (( SECONDS - t0 < $3 )); do
    akget "$SCN_TOKENS/scn-reader.token" "conda/conda-fake-upstream/$1/repodata.json" >/dev/null
    jq -e "$2" "$WORK/last.body" >/dev/null 2>&1 && { echo $((SECONDS - t0)); return 0; }
    sleep 5
  done; echo $((SECONDS - t0)); return 1
}
