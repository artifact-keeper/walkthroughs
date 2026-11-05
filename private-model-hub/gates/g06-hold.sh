#!/usr/bin/env bash
# G6 Scan and hold on hf-staging: the upload hold, scan on upload, block_unscanned, a
# reviewer's hold, release and reject. Each run publishes a new model, acme/g6-<RUNID>.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G6
MODEL=acme/g6-$RUNID
SRC="$ROOT/out/models/embedder"
up() { # FILE NAME -> artifact id
  call publisher POST "$HFAPI/hf-staging/api/models/$MODEL/upload/main" -H "X-Filename: $2" --data-binary "@$1" >/dev/null
  api GET "/repositories/hf-staging/artifacts?per_page=200" | jq -r --arg p "$MODEL/main/$2" '.items[] | select(.path == $p) | .id'
}
get() { call developer "${2:-GET}" "$HFAPI/hf-staging/$MODEL/resolve/main/$1" >/dev/null; }
wait_scan() {
  for _ in $(seq 60); do
    api GET "/security/artifacts/$1/scans" | jq -e 'any(.items[]; .scan_type == "grype" and .status == "completed")' >/dev/null && return 0
    sleep 2
  done; return 1
}
qstatus() { api GET "/quarantine/$1" | jq -r .quarantine_status; }
api PUT /repositories/hf-staging/security -d '{"scan_enabled":true,"scan_on_upload":true}' >/dev/null

id=$(up "$SRC/model.safetensors" model.safetensors)
check $G "scan on upload runs: grype completes on a model file" "no completed grype scan" wait_scan "$id"
api GET "/security/artifacts/$id/scans" | jq -c '[.items[] | {scan_type, status, findings_count}]'
get model.safetensors
check $G "a model file with a clean scan is released and downloads (status clean, 200)" "$(qstatus "$id"), $(why)" \
  bash -c "[[ '$(qstatus "$id")' == clean && \$(cat '$FOUT/.code') == 200 ]]"

python3 -I -c 'import struct,sys; c=b"echo pickle-payload-ran"; open(sys.argv[1],"wb").write(b"\x80\x02cposix\nsystem\nq\x00X"+struct.pack("<I",len(c))+c+b"q\x01\x85q\x02Rq\x03.")' "$ROOT/out/models/payload.bin"
pid=$(up "$ROOT/out/models/payload.bin" pytorch_model.bin)
wait_scan "$pid"
api GET "/security/artifacts/$pid/scans" | jq -c '[.items[] | {scan_type, status, findings_count}]'
f=$(api GET "/security/artifacts/$pid/scans" | jq '[.items[].findings_count // 0] | add')
if [[ $f -gt 0 || $(qstatus "$pid") =~ ^(quarantined|rejected|flagged)$ ]]; then
  pass $G "a pickle checkpoint whose load runs a shell command is flagged by a scan"
else
  blocked ak-gap $G "a pickle checkpoint whose load runs a shell command is flagged by a scan" \
    "no scanner reads pickle, safetensors or GGUF; it is released as clean (#3013, #2382; findings F4)"
fi
api POST "/quarantine/$pid/quarantine" -d '{"reason":"gate G6"}' >/dev/null
get pytorch_model.bin
check $G "a reviewer's hold refuses the download (409)" "$(why)" is 409
get pytorch_model.bin HEAD
check $G "a held file's HEAD is refused too (409)" "$(why)" is 409
api POST "/quarantine/$pid/reject" -d '{"reason":"gate G6: pickle"}' >/dev/null
get pytorch_model.bin
check $G "a rejected file is refused (403)" "$(why)" is 403

api PUT /repositories/hf-staging/security -d '{"scan_enabled":true,"scan_on_upload":false}' >/dev/null
uid=$(up "$SRC/config.json" config.json)
get config.json
check $G "with no scan yet, a new upload is held (409)" "$(why)" is 409
api POST "/quarantine/$uid/release" -d '{"reason":"gate G6"}' >/dev/null
get config.json
check $G "released but unscanned, block_unscanned refuses it (403)" "$(why)" is 403
api POST /security/scan -d "$(jq -nc --arg a "$uid" '{artifact_id:$a}')" >/dev/null
wait_scan "$uid"; get config.json
check $G "after its scan completes it downloads (200)" "$(why)" is 200
api PUT /repositories/hf-staging/security -d '{"scan_enabled":true,"scan_on_upload":true}' >/dev/null
