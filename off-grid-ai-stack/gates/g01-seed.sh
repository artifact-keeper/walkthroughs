#!/usr/bin/env bash
# G1 Seed: everything in seed/manifest.toml is in the registry, the model was seeded with the
# cache-seed API at its commit, every Remote sent its traffic through the egress ledger, and
# what went out while seeding is listed twice: in the ledger and as UPSTREAM_FETCHED rows.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G1
INV="$ROOT/out/inventory/seed.tsv"
check $G "the inventory of record exists (make vet writes it)" "no out/inventory/seed.tsv" test -s "$INV"
for k in image model python npm mcp plugin; do
  n=$(awk -F'\t' -v k=$k '$1 == k' "$INV" | wc -l); miss=$(awk -F'\t' -v k=$k '$1 == k && $3 == "-"' "$INV" | wc -l)
  echo "inventory $k: $n items, $miss missing"
  check $G "inventory: every $k of the manifest is served, with a digest ($n)" "$miss of $n missing: $(awk -F'\t' -v k=$k '$1 == k && $3 == "-" {print $2}' "$INV" | head -3 | tr '\n' ' ')" \
    test "$n" -gt 0 -a "$miss" -eq 0
done

job=$(cat "$ROOT/out/seed-job-hf-hub" 2>/dev/null)
api GET "/repositories/hf-hub/cache/seed/$job" > "$GOUT/g1-seed-job.json"
jq -c '{status, summary}' "$GOUT/g1-seed-job.json"
check $G "the hf-hub cache-seed job completed with every path cached (#5333)" "$(jq -c '{status, summary}' "$GOUT/g1-seed-job.json")" \
  jq -e '.status == "completed" and all(.items[]; .state == "cached" or .state == "already_cached")' "$GOUT/g1-seed-job.json"
seeded=$(jq -r --arg f "$MODEL_GGUF" '.items[] | select(.path | endswith("/" + $f)) | .checksum_sha256' "$GOUT/g1-seed-job.json")
served=$(awk -F'\t' -v n="hf-models:$MODEL_REPO/$MODEL_GGUF" '$1 == "model" && $2 == n {print $3}' "$INV")
echo "GGUF: seeded into hf-hub ${seeded:0:16}, served by hf-models ${served:0:16}"
check $G "the GGUF hf-models serves is the file the seed job cached from huggingface.co (same SHA-256)" "seeded $seeded, served $served" \
  test -n "$seeded" -a "$seeded" == "$served"

bad=0
for r in "${REMOTES[@]}"; do
  m=$(call admin GET "/api/v1/repositories/$r/egress-proxy" | jq -r '.mode + " " + (.proxy_url // "")')
  [[ $m == "explicit http://egress-ledger:3128"* ]] || { echo "  $r: $m"; bad=$((bad + 1)); }
done
check $G "every Remote sends its upstream traffic through the egress ledger (explicit egress proxy)" "$bad Remotes do not" test $bad -eq 0

t0=$(cat "$ROOT/out/seed-started" 2>/dev/null)
echo "ledger hosts since the seed started ($t0):"
jq -r --arg t "$t0" 'select(.t >= $t and .event == "open") | .host' "$LEDGER_FILE" | sort | uniq -c | sort -rn | tee "$GOUT/g1-ledger-hosts.txt"
expected='^(registry-1\.docker\.io|ak-central|auth\.docker\.io|.*\.docker\.(com|io)|.*cloudflare\.docker\.com|ghcr\.io|pkg-containers\.githubusercontent\.com|.*\.githubusercontent\.com|pypi\.org|files\.pythonhosted\.org|registry\.npmjs\.org|huggingface\.co|.*\.huggingface\.co|.*\.hf\.co|registry\.modelcontextprotocol\.io)$'
odd=$(jq -r --arg t "$t0" 'select(.t >= $t and .event == "open") | .host' "$LEDGER_FILE" | sort -u | grep -Ev "$expected" || true)
check $G "the ledger recorded the seed's traffic, to the expected upstreams only" "unexpected hosts: $(echo $odd)" \
  bash -c "[[ -s '$GOUT/g1-ledger-hosts.txt' && -z '$odd' ]]"

audit_items UPSTREAM_FETCHED "$t0" > "$GOUT/g1-upstream-fetched.jsonl"
echo "UPSTREAM_FETCHED rows since the seed started: $(wc -l < "$GOUT/g1-upstream-fetched.jsonl"), by repository and host:"
jq -r '"\(.details.repository) \(.details.host)"' "$GOUT/g1-upstream-fetched.jsonl" | sort | uniq -c | sort -rn | head -20
missing=""
for r in oci-dockerhub oci-ghcr pypi-remote npm-remote hf-hub mcp-official plugins; do
  grep -q "\"repository\":\"$r\"" "$GOUT/g1-upstream-fetched.jsonl" || missing+="$r "
done
check $G "every Remote's upstream requests are UPSTREAM_FETCHED audit rows (AUDIT_UPSTREAM_FETCHES=all, #5316)" "no rows for: $missing" test -z "$missing"
fh=$(jq -r '.details.host' "$GOUT/g1-upstream-fetched.jsonl" | sort -u | grep -Ev "$expected" || true)
check $G "the audit rows name the same upstreams the ledger saw" "audit hosts not expected: $(echo $fh)" test -z "$fh"
