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

verdict() { # STATUS CHECK [WHY]
  local line; line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%FT%TZ)" "$1" "$SID" "$2" "${3:-}")
  echo "$line" >> "$SCN_RESULTS"
  printf '%-12s %-4s %s%s\n' "$1" "$SID" "$2" "${3:+: $3}"
}
pass()    { verdict PASS "$@"; }
fail()    { verdict FAIL "$@"; SCN_FAILED=1; }
blocked() { local f=$1; shift; verdict "BLOCKED($f)" "$@"; }
check()   { # COND-EXIT-CODE CHECK [WHY-IF-FAIL]: pass if $1 == 0
  if [[ $1 == 0 ]]; then pass "$2"; else fail "$2" "${3:-}"; fi; }
ev() { EVIDENCE+=("$*"); echo "  > $*"; }
on_exit() { RESTORE+=("$1"); }
note() { echo "-- $*"; }

scn_begin() { # ID NAME DESCRIPTION
  SID=$1; SNAME=$2; SLOG="$SCN_OUT/$1-$2.log"; SCN_FAILED=0
  exec 3>&1 4>&2
  exec > >(tee "$SLOG") 2>&1; TEE_PID=$!
  trap scn_exit EXIT
  trap 'exit 130' INT TERM
  echo "=== $SID $SNAME: $3"
  echo "    $(date -u +%FT%TZ); backend $(podman inspect ak-conda-backend --format '{{.ImageName}}' 2>/dev/null);" \
       "nexus $(podman inspect scn-nexus --format '{{.ImageName}}' 2>/dev/null); log $SLOG"
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
  on_exit al_restore
}
al_restore() {
  local f="$WORK/allowlist.$SID.json" c
  if jq -e .absent "$f" >/dev/null 2>&1; then c=$(akapi DELETE /repositories/conda-virtual/allowlist -o /dev/null -w '%{http_code}')
  else c=$(akapi PUT /repositories/conda-virtual/allowlist -o /dev/null -w '%{http_code}' -d "$(jq -c '{enabled, entries: (.entries // [])}' "$f")"); fi
  echo "   allowlist restored: HTTP $c, now $(akapi GET /repositories/conda-virtual/allowlist | jq -c '{enabled, entry_count}')"
}
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

# --- pixi -------------------------------------------------------------------
# px VIA DIR VOLUME pixi-args...   VIA: ak (image config: straight to ak.internal),
#   nexus (scenarios/nexus/pixi-config.toml), or a path to a pixi config.toml.
# Sets PX_RC, PX_S (seconds), PX_OUT (output file, WARN lines dropped). VOLUME "new:<name>" starts cold.
px() {
  local via=$1 dir; dir=$(cd "$2" && pwd); local vol=$3; shift 3
  local cfg=() auth="${PX_AUTH:-$TOKENS/consumer-auth.json}"
  case $via in ak) ;; nexus) cfg=(-v "$SCN_DIR/nexus/pixi-config.toml:/etc/pixi/config.toml:ro,z") ;;
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
    [[ $(nx_has ak-virtual "${f%%-[0-9]*}" "/noarch/$f") == 0 ]] || continue
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
# Wait until Artifact Keeper's conda-fake-upstream remote serves what the predicate (jq -e) says.
fu_wait() { # SUBDIR JQ_PREDICATE TIMEOUT_S -> seconds waited, rc 1 on timeout
  local t0=$SECONDS
  while (( SECONDS - t0 < $3 )); do
    akget "$SCN_TOKENS/scn-reader.token" "conda/conda-fake-upstream/$1/repodata.json" >/dev/null
    jq -e "$2" "$WORK/last.body" >/dev/null 2>&1 && { echo $((SECONDS - t0)); return 0; }
    sleep 5
  done; echo $((SECONDS - t0)); return 1
}
