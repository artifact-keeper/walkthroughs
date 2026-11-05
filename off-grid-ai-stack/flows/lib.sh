# shellcheck shell=bash disable=SC2034  # sourced: the variables are used by the callers
# Helpers for the flow scripts (make seed, vet, disconnect, agent, claude) and the gates.
FLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../registry/lib.sh
source "$FLOWS_DIR/../registry/lib.sh"
load_env
U=$(AK_HOST_URL)
RUN="$ROOT/agent/run.sh"
FOUT="$ROOT/out/flows"; mkdir -p "$FOUT"
LEDGER_FILE="$ROOT/out/ledger/ledger.jsonl"
MANIFEST="$ROOT/seed/manifest.toml"
P="localhost:${HTTPS_PORT}"            # the registry as the host's podman sees it
REMOTES=(oci-dockerhub oci-ghcr pypi-remote npm-remote hf-hub mcp-official plugins)
LLAMA="$PROJECT-llama"

say() { printf '\n== %s\n' "$*"; }
# call WHO METHOD PATH [curl args]: WHO is admin, a token name (developer, publisher), - (anonymous).
# Prints the body; the HTTP status goes to $FOUT/.code and the response headers to $FOUT/.headers.
call() {
  local who=$1 m=$2 p=$3; shift 3; local H=() mflag=(-X "$m")
  case $who in
    -) ;;
    admin) H=(-H "Authorization: Bearer $(admin_token)") ;;
    *) H=(-H "Authorization: Bearer $(tok "$who")") ;;
  esac
  [[ $m == HEAD ]] && mflag=(-I)
  # A caller's own -o FILE takes the body (curl uses the first -o it sees); .body is then empty.
  local o=(-o "$FOUT/.body") a
  for a in "$@"; do [[ $a == -o ]] && { o=(); : > "$FOUT/.body"; }; done
  akcurl -sS "${mflag[@]}" "${H[@]}" -D "$FOUT/.headers" "${o[@]}" -w '%{http_code}' "$@" "$U$p" > "$FOUT/.code"
  cat "$FOUT/.body"
}
code() { cat "$FOUT/.code"; }
hdr() { grep -i "^$1:" "$FOUT/.headers" | tail -1 | cut -d' ' -f2- | tr -d '\r'; }
show() {
  call "$@" >/dev/null
  echo "HTTP $(code)"; jq -c . "$FOUT/.body" 2>/dev/null || head -c 300 "$FOUT/.body"; echo
}
# api METHOD PATH [curl args]: an admin call to /api/v1 with a JSON body
api() { local m=$1 p=$2; shift 2; call admin "$m" "/api/v1$p" -H 'Content-Type: application/json' "$@"; }
repo_id() { api GET "/repositories/$1" | jq -r .id; }

# manifest QUERY: run a jq query over seed/manifest.toml (read as JSON by python3's tomllib).
# With SMALL_MODEL=1 the model entry marked small is "the model"; otherwise the default one.
manifest() {
  python3 -I -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$MANIFEST" | jq -r "$@"
}
# The model choice is made once, at make seed, and remembered in out/small-model, so the later
# steps and the gates use the same model without SMALL_MODEL being set again.
if [[ -z ${SMALL_MODEL:-} && -s $ROOT/out/small-model ]]; then SMALL_MODEL=$(<"$ROOT/out/small-model"); fi
export SMALL_MODEL=${SMALL_MODEL:-0}
model_sel() { if [[ ${SMALL_MODEL:-0} == 1 ]]; then echo '.model[] | select(.small)'; else echo '.model[] | select(.default)'; fi; }
MODEL_REPO=$(manifest "$(model_sel) | .repo_id")
MODEL_REV=$(manifest "$(model_sel) | .revision")
MODEL_GGUF=$(manifest "$(model_sel) | .gguf")

# metric NAME LABELS: the sum of a Prometheus counter over the series whose labels contain
# every comma-separated k="v" given, from GET /api/v1/admin/metrics
metric() {
  call admin GET /api/v1/admin/metrics >/dev/null
  awk -v n="$1" -v want="$2" '
    BEGIN { k = split(want, w, ",") }
    index($0, n "{") == 1 || $1 == n {
      ok = 1; for (i = 1; i <= k; i++) if (w[i] != "" && index($1, w[i]) == 0) ok = 0
      if (ok) s += $2
    } END { printf "%d\n", s }' "$FOUT/.body"
}
# audit_count ACTION [SINCE-RFC3339]: how many audit rows of ACTION exist (at or after SINCE)
audit_count() {
  api GET "/admin/audit?action=$1&per_page=1${2:+&from=$(jq -rn --arg s "$2" '$s|@uri')}" \
    | jq -r '.total // .pagination.total // (.items | length)'
}
# audit_rows ACTION [N]: the newest audit rows of ACTION, compact
audit_rows() {
  api GET "/admin/audit?action=$1&per_page=${2:-20}" | jq -c '.items[] | {at: .created_at, action, details}'
}
# ledger_lines: how many connections the ledger has seen opened (its `open` lines)
ledger_lines() { [[ -f $LEDGER_FILE ]] && jq -c 'select(.event == "open")' "$LEDGER_FILE" | wc -l || echo 0; }
ledger_hosts() { [[ -f $LEDGER_FILE ]] && jq -r 'select(.event == "open") | .host' "$LEDGER_FILE" | sort | uniq -c | sort -rn; }
# pull_image REPO REF: podman pull through the registry from the host; prints the digest
pull_image() {
  podman pull -q --cert-dir "$OUT/certs.d/$P" --authfile "$TOKENS/developer-podman.json" "$P/$1/$2" >/dev/null
  podman image inspect "$P/$1/$2" --format '{{.Digest}}'
}
# wait_seed REPO JOB: poll a cache-seed job until it finishes; prints the final document
wait_seed() {
  local i
  for i in $(seq 900); do
    api GET "/repositories/$1/cache/seed/$2" >/dev/null
    jq -e '.status == "completed" or .status == "failed"' "$FOUT/.body" >/dev/null && break
    sleep 2
  done
  cat "$FOUT/.body"
}
# audit_items ACTION [SINCE] [PAGES]: every audit row of ACTION (newest first), one JSON per line
audit_items() {
  local page=1 n
  while (( page <= ${3:-50} )); do
    api GET "/admin/audit?action=$1&per_page=200&page=$page${2:+&from=$(jq -rn --arg s "$2" '$s|@uri')}" > "$FOUT/.audit"
    jq -c '.items[]' "$FOUT/.audit"
    n=$(jq '.items | length' "$FOUT/.audit"); (( n == 200 )) || break; page=$((page + 1))
  done
}
