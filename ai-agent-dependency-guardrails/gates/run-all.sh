#!/usr/bin/env bash
# The walkthrough's gates G1-G10 (plan.md). Each prints PASS, FAIL or BLOCKED(Fn) with its
# evidence; results go to out/gates/<gate>.txt and out/gates/summary.txt.
# Needs the full pipeline first (make all): the agent transcripts in agent/out are evidence.
# BLOCKED(Fn) = the check depends on an Artifact Keeper gap listed in plan.md; it is reported,
# not counted as a failure. Exit status 1 if any gate FAILs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/policies/lib.sh"
G="$ROOT/out/gates"; rm -rf "$G"; mkdir -p "$G"
AGENT="$(cat "$TOKENS/agent.token")"
RUN="$ROOT/sandbox/run.sh"
fails=0

gate() { # gate ID "title" status evidence...
  local id=$1 title=$2 status=$3; shift 3
  printf '%s\n' "$id $title: $status" "$@" > "$G/$id.txt"
  printf '%-4s %-12s %s\n' "$id" "$status" "$title" | tee -a "$G/summary.txt"
  [[ $status == PASS || $status == BLOCKED* || $status == "NOT RUN" ]] || fails=$((fails + 1))
}
step() { jq -r --arg id "$1" '.[] | select(.id==$id) | .pass' "$ROOT/agent/out/summary.json" 2>/dev/null; }
steps_pass() { local s; for s in "$@"; do [[ $(step "$s") == true ]] || return 1; done; }
http() { # http TOKEN URL -> "code body"
  akcurl -sS -H "Authorization: Bearer $1" -w '\n%{http_code}' "$2" | { b=$(cat); echo "${b##*$'\n'} ${b%$'\n'*}"; }
}

# G1 sandbox network ----------------------------------------------------------------
out=$("$RUN" -w /tmp -- python3 - <<'EOF'
import urllib.request
for url in ["https://ak.internal/readyz", "https://pypi.org/simple/", "https://registry.npmjs.org/", "https://github.com/"]:
    try:
        print("reached", url, urllib.request.urlopen(url, timeout=5).status)
    except Exception as e:
        print("no route", url, type(e).__name__)
EOF
)
[[ $(grep -c '^reached' <<<"$out") == 1 && $out == *"reached https://ak.internal/readyz 200"* ]] && s=PASS || s=FAIL
gate G1 "sandbox reaches the registry and nothing else" $s "$out"

# G2 happy path, no credentials in project files -------------------------------------
out=$("$RUN" -- sh -c 'uv sync --locked -q && npm ci --ignore-scripts --silent && .venv/bin/python main.py' 2>&1)
# Download sources only (package-lock "funding" links to github.com etc. are not sources).
hosts=$( { grep -oE '(registry|url) = "https?://[^/"]+' "$ROOT/app/uv.lock" | grep -oE 'https?://[^/"]+'
           jq -r '.packages[] | .resolved // empty' "$ROOT/app/package-lock.json" | grep -oE '^https?://[^/]+'; } | sort -u | tr '\n' ' ')
creds=$(grep -liE 'authtoken|bearer|password|token=' "$ROOT/app/"{pyproject.toml,uv.lock,package.json,package-lock.json} || true)
[[ $out == *"MCP tools: list_tickets"* && $hosts == "https://ak.internal " && -z $creds ]] && s=PASS || s=FAIL
gate G2 "uv sync + npm ci in the sandbox, app runs, lockfiles name only the registry" $s "$out" "download hosts in lockfiles: $hosts" "files with credentials: ${creds:-none}"

# G3 invented and look-alike names --------------------------------------------------
probe=$(http "$AGENT" "$U/pypi/pypi-virtual/simple/huggingface-cli/")
"$ROOT/policies/approve.sh" pypi humanize "G3: approved after review" >/dev/null
after=$("$RUN" -w /tmp -- uv pip install -q --target /tmp/site --no-deps humanize 2>&1 && echo installed)
steps_pass invented-name look-alike unreviewed-mcp && [[ $probe == 403*curation_blocked* && $after == *installed* ]] && s=PASS || s=FAIL
gate G3 "unknown names refused (curation_blocked) before any fetch; one approval makes a name installable" $s \
  "huggingface-cli: $probe" "humanize after policies/approve.sh: $after" \
  "look-alike detection on the proxy path (typosquat rules): F7, not used"

# G4 cooldown -----------------------------------------------------------------------
probe=$(http "$AGENT" "$U/pypi/pypi-lab-virtual/simple/lab-agent-sdk/lab_agent_sdk-1.1.0-py3-none-any.whl")
rev=$(body_of "$(api GET '/admin/age-gate/reviews?per_page=100')" | jq -c '[.items[] | {package_name,package_version,status}]')
steps_pass fresh-pinned fresh-unpinned fresh-npm && [[ $probe == 451*age_gate_blocked* ]] && s=PASS || s=FAIL
gate G4 "fresh versions held (451 age_gate_blocked); unpinned resolves the newest old-enough; exceptions reviewed" $s \
  "lab-agent-sdk 1.1.0: $probe" "age-gate reviews: $rev" "no client-side cooldown is configured in the sandbox: the registry does this alone"

# G5 name squat ---------------------------------------------------------------------
filt=$(http "$ADMIN" "$U/npm/npm-remote/@acme%2ftickets-mcp")
lab=$(http "$ADMIN" "$U/npm/npm-lab/@acme%2ftickets-mcp" | cut -c1-3)
virt=$(akcurl -sS -H "Authorization: Bearer $AGENT" "$U/npm/npm-lab-virtual/@acme%2ftickets-mcp" | jq -c '{versions:(.versions|keys),latest:."dist-tags".latest}')
steps_pass squat-pypi squat-npm && [[ $filt == 404* && $lab == 200 && $virt == '{"versions":["1.0.0"],"latest":"1.0.0"}' ]] && s=PASS || s=FAIL
gate G5 "internal names never come from a public upstream" $s "npm-lab has @acme/tickets-mcp 99.0.0: HTTP $lab" \
  "npm-lab-virtual offers: $virt" "npm-remote @acme/* (upstream filter): ${filt:0:3}"

# G6 known-vulnerable versions ------------------------------------------------------
lc=$(http "$AGENT" "$U/pypi/pypi-virtual/simple/langchain/langchain-0.0.141-py3-none-any.whl")
bp=$(http "$AGENT" "$U/npm/npm-virtual/body-parser/-/body-parser-2.3.0.tgz")
steps_pass old-tutorial-pin && [[ $lc == 403*scan_blocked* && $bp == 403*scan_blocked* ]] && s=PASS || s=FAIL
gate G6 "versions with high or critical advisories refused (scan_blocked), fail closed" $s "langchain 0.0.141: $lc" "body-parser 2.3.0: $bp"

# G7 MCP servers --------------------------------------------------------------------
steps_pass unreviewed-mcp squat-npm && grep -q "MCP tools: list_tickets" "$G/G2.txt" && s=PASS || s=FAIL
gate G7 "internal MCP server installs pinned from the registry and runs; npx -y of an unreviewed server refused" $s \
  "$(grep -A1 'what the registry said' "$ROOT"/agent/out/*unreviewed-mcp.txt | tail -1)"

# G8 the agent's token --------------------------------------------------------------
r1=$(http "$AGENT" "$U/pypi/pypi-remote/simple/idna/" | cut -c1-3)
r2=$(http "$AGENT" "$U/api/v1/admin/audit" | cut -c1-3)
r3=$(http "$AGENT" "$U/api/v1/repositories/oci-dockerhub" | cut -c1-3)
steps_pass publish && [[ $r1 =~ ^40[134]$ && $r2 =~ ^40[13]$ ]] && s=PASS || s=FAIL
gate G8 "agent token reads the virtuals only: no remote directly, no admin API, no publish" $s \
  "pypi-remote direct: $r1" "admin audit API: $r2" "oci-dockerhub repo API: $r3" "npm publish: see agent/out/*publish.txt"

# G9 what did the agent try? --------------------------------------------------------
scans=$(for k in pypi-remote npm-remote; do body_of "$(api GET "/repositories/$k/security/proxy-scans?per_page=500")" \
          | jq -r --arg k "$k" '.items[] | select(.state=="vulnerable") | "\($k) \(.path) \(.max_severity)"'; done)
held=$(body_of "$(api GET '/admin/age-gate/reviews?per_page=100')" | jq -r '.items[] | "\(.repository_key) \(.package_name) \(.package_version) \(.status) x\(.request_count)"')
audit=$(body_of "$(api GET '/admin/audit?per_page=200')" | jq -r '[.items[]?.action] | map(select(test("CURATION|SCAN|AGE_GATE|PROXY";"i"))) | unique | join(" ")')
gate G9 "refusals can be listed: scan blocks and held versions yes; curation blocks only via F1" "BLOCKED(F1)" \
  "scan-on-proxy refusals:" "$scans" "held versions (age-gate reviews):" "$held" "audit log actions about refusals: ${audit:-none}"

# G10 reproducible ------------------------------------------------------------------
if [[ -s "$ROOT/out/reproduce.txt" ]]; then
  grep -q '^run 2: PASS' "$ROOT/out/reproduce.txt" && s=PASS || s=FAIL
  gate G10 "make clean all gates, twice, from an empty registry" $s "$(cat "$ROOT/out/reproduce.txt")"
else
  gate G10 "make clean all gates, twice, from an empty registry" "NOT RUN" "run gates/reproduce.sh"
fi

echo "gates: $(grep -c ' PASS ' "$G/summary.txt") PASS, $(grep -c 'BLOCKED' "$G/summary.txt") BLOCKED, $fails FAIL; evidence in $G"
exit $(( fails > 0 ))
