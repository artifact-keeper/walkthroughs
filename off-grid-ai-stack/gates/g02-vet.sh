#!/usr/bin/env bash
# G2 Vet: the model the site will run was scanned by the model-file scanner and is served; a
# truncated GGUF and a pickle that calls os.system are flagged and refused; the scanner
# adapter runs offline on an imported database and scans an image; the configuration exports
# as one document that plans clean against this instance. Reads what flows/vet.sh left.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G2
aid() { api GET "/repositories/hf-models/artifacts?per_page=200" | jq -r --arg p "$1" '.items[] | select(.path == $p) | .id' | head -1; }
scans_of() { api GET "/security/artifacts/$1/scans" > "$GOUT/g2-scans-$2.json"; jq -c '[.items[] | {scan_type, status, findings_count}]' "$GOUT/g2-scans-$2.json"; }

id=$(aid "$MODEL_REPO/main/$MODEL_GGUF")
echo "hf-models $MODEL_GGUF ($id): $(scans_of "$id" gguf)"
check $G "the model-file scanner scanned the GGUF in hf-models (scan_type model, completed, #5337)" "$(jq -c '[.items[] | {scan_type, status}]' "$GOUT/g2-scans-gguf.json")" \
  jq -e 'any(.items[]; .scan_type == "model" and .status == "completed")' "$GOUT/g2-scans-gguf.json"
check $G "the GGUF has no model-scanner finding" "$(jq -c '[.items[] | select(.scan_type == "model") | .findings_count]' "$GOUT/g2-scans-gguf.json")" \
  jq -e 'all(.items[] | select(.scan_type == "model"); (.findings_count // 0) == 0)' "$GOUT/g2-scans-gguf.json"
call developer HEAD "/huggingface/hf-models/$MODEL_REPO/resolve/main/$MODEL_GGUF" >/dev/null
check $G "hf-models serves the scanned GGUF (policy hf-models-vetted: block_unscanned, max_severity medium)" "HTTP $(code)" is 200

for t in "truncated acme-lab/truncated-gguf/main/model.gguf" "pickle acme-lab/backdoored/main/pytorch_model.bin"; do
  read -r k path <<<"$t"
  i=$(aid "$path")
  echo "$path ($i): $(scans_of "$i" "$k")"
  sid=$(jq -r '[.items[] | select(.scan_type == "model")][0].id // empty' "$GOUT/g2-scans-$k.json")
  api GET "/security/scans/$sid/findings?per_page=50" > "$GOUT/g2-findings-$k.json" 2>/dev/null
  jq -c '[(.items // .)[]? | {severity, component: .affected_component, title: ((.title // "")[0:60])}]' "$GOUT/g2-findings-$k.json" 2>/dev/null
  check $G "$k: the model-file scanner reports it" "$(jq -c '[.items[] | {scan_type, status, findings_count}]' "$GOUT/g2-scans-$k.json")" \
    jq -e 'any(.items[]; .scan_type == "model" and (.findings_count // 0) > 0)' "$GOUT/g2-scans-$k.json"
  call developer GET "/huggingface/hf-models/${path%%/main/*}/resolve/main/${path##*/}" -o /dev/null >/dev/null
  check $G "$k: hf-models refuses to serve it" "HTTP $(code)" bash -c "[[ \$(cat '$FOUT/.code') =~ ^(403|404|409|451)\$ ]]"
done
if jq -e '[(.items // .)[]? | select((.affected_component // "") | test("dangerous-global"))] | length > 0' "$GOUT/g2-findings-pickle.json" >/dev/null 2>&1; then
  pass $G "pickle: the finding is model.pickle.dangerous-global (os.system)"
else
  fail $G "pickle: the finding is model.pickle.dangerous-global (os.system)" "$(head -c 200 "$GOUT/g2-findings-pickle.json")"
fi

# The scanner adapter (vet.sh imported the DB and asked for a scan)
check $G "scanner adapter: the trivy DB import was accepted (PUT /api/v1/vulndb, #5314)" "$(head -c 200 "$FOUT/vulndb-import.txt" 2>/dev/null)" \
  bash -c "[[ \$(head -1 '$FOUT/vulndb-import.txt' 2>/dev/null) == 200 ]]"
check $G "scanner adapter: offline, with the imported DB's age reported" "$(cat "$FOUT/vulndb.json" 2>/dev/null)" \
  jq -e '.offline == true and (.age_seconds | type) == "number"' "$FOUT/vulndb.json"
check $G "scanner adapter: a scan of the llama.cpp image from the registry completes offline" "$(tail -c 200 "$FOUT/adapter-report.txt" 2>/dev/null)" \
  bash -c "[[ \$(head -1 '$FOUT/adapter-report.txt' 2>/dev/null) == 200 ]] && tail -n +2 '$FOUT/adapter-report.txt' | jq -e '.vulnerabilities | type == \"array\"' >/dev/null"

C="$ROOT/out/config"
n=$(jq '.repositories | length' "$C/seed.json" 2>/dev/null || echo 0)
want=$(api GET "/repositories?per_page=200" | jq '(.items // .) | length')
check $G "config export: one document with every repository ($n of $want, #5335)" "export has $n, the instance $want" test "$n" -eq "$want" -a "$n" -gt 0
check $G "config export: no credential in it (the plugins Remote's token is a secret_ref)" "a token appears in out/config/seed.json" \
  bash -c "! grep -qF '$(tok site-sync)' '$C/seed.json' && jq -e '[.. | objects | select(has(\"secret_ref\"))] | length > 0' '$C/seed.json' >/dev/null"
check $G "config plan: the export planned against this instance changes nothing" "$(jq -c '{create, update, errors}' "$C/plan-seed.json" 2>/dev/null)" \
  jq -e '(.create | length) == 0 and (.update | length) == 0 and (.errors | length) == 0' "$C/plan-seed.json"
