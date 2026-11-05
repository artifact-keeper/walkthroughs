#!/usr/bin/env bash
# Step 6: scan and hold. hf-staging is a Local repository where every new file is held
# (quarantine, up to 24 h) until a scan clears it or a reviewer releases it, and a scan policy
# refuses any file no scanner has finished (block_unscanned) or that has a high finding.
# Scanning runs on upload (grype and the dependency scanner). There is no model-file scanner:
# a pickle checkpoint whose load runs a shell command is scanned, found clean and released.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODEL=acme/embedder-rc

say "hf-staging: upload hold 24 h, scan on upload, policy block_unscanned"
ensure_repo hf-staging '{"key":"hf-staging","name":"Model staging (held until reviewed)","format":"huggingface",
  "repo_type":"local","visibility":"private"}'
# quarantine_* are not accepted at creation (they are ignored there); set them with PATCH.
api PATCH /repositories/hf-staging -d '{"quarantine_enabled":true,"quarantine_duration_minutes":1440}' \
  | jq -c '{key, quarantine_enabled, quarantine_duration_minutes}'
grant user publisher hf-staging '["read","write"]'
grant user developer hf-staging '["read"]'
api PUT /repositories/hf-staging/security -d '{"scan_enabled":true,"scan_on_upload":true}' \
  | jq -c '{scan_enabled, scan_on_upload}'
pol=$(api GET /security/policies | jq -r '(if type=="array" then . else .items end)[] | select(.name=="hf-staging-scanned") | .id' | head -1)
if [[ -z $pol ]]; then
  api POST /security/policies -d "$(jq -nc --arg r "$(repo_id hf-staging)" '{name:"hf-staging-scanned",
    repository_id:$r,max_severity:"high",block_unscanned:true,block_on_fail:true}')" \
    | jq -c '{name, max_severity, block_unscanned, block_on_fail}'
fi

up() { # FILE-ON-DISK NAME-IN-REPO -> artifact id
  call publisher POST "$HFAPI/hf-staging/api/models/$MODEL/upload/main" -H "X-Filename: $2" --data-binary "@$1" >/dev/null
  echo "upload $2: HTTP $(code)" >&2
  api GET "/repositories/hf-staging/artifacts?per_page=100" | jq -r --arg p "$MODEL/main/$2" '.items[] | select(.path == $p) | .id'
}
get() { call developer GET "$HFAPI/hf-staging/$MODEL/resolve/main/$1" >/dev/null; echo "  GET $1: HTTP $(code) $(jq -r '.code // empty' "$FOUT/.body" 2>/dev/null)"; }
status() { api GET "/quarantine/$1" | jq -c '{quarantine_status, quarantine_until, is_blocked}'; }
scans() { api GET "/security/artifacts/$1/scans" | jq -c '[.items[] | {scan_type, status, findings_count}]'; }
wait_scan() { # ID: until a grype scan of it has completed
  for _ in $(seq 60); do
    api GET "/security/artifacts/$1/scans" | jq -e 'any(.items[]; .scan_type == "grype" and .status == "completed")' >/dev/null && return 0
    sleep 2
  done; return 1
}

say "a model file: held on upload until its scan completes (here: well under a second)"
id=$(up "$ROOT/out/models/embedder/model.safetensors" model.safetensors)
get model.safetensors
wait_scan "$id"; echo "  scans: $(scans "$id")"; echo "  quarantine: $(status "$id")"
get model.safetensors

say "a pickle checkpoint whose load runs a shell command: held, scanned, found clean, released"
python3 -I - "$ROOT/out/models/payload.bin" <<'PY'
import struct, sys
cmd = b"echo pickle-payload-ran"   # what torch.load(weights_only=False) would execute
open(sys.argv[1], "wb").write(b"\x80\x02cposix\nsystem\nq\x00X" + struct.pack("<I", len(cmd)) + cmd + b"q\x01\x85q\x02Rq\x03.")
PY
pid=$(up "$ROOT/out/models/payload.bin" pytorch_model.bin)
get pytorch_model.bin
wait_scan "$pid"; echo "  scans: $(scans "$pid")"; echo "  quarantine: $(status "$pid")"
get pytorch_model.bin
say "a reviewer holds it, then rejects it"
api POST "/quarantine/$pid/quarantine" -d '{"reason":"pickle checkpoint: review"}' | jq -c '{new_status}'
get pytorch_model.bin
api POST "/quarantine/$pid/reject" -d '{"reason":"pickle checkpoints are not accepted; publish safetensors"}' | jq -c '{new_status}'
get pytorch_model.bin

say "scan on upload off: the hold lasts until a reviewer releases the file; block_unscanned then refuses it until a scan completes"
api PUT /repositories/hf-staging/security -d '{"scan_enabled":true,"scan_on_upload":false}' | jq -c '{scan_on_upload}'
uid=$(up "$ROOT/out/models/embedder/config.json" config.json)
get config.json
api POST "/quarantine/$uid/release" -d '{"reason":"reviewed"}' | jq -c '{new_status}'
get config.json
api POST /security/scan -d "$(jq -nc --arg a "$uid" '{artifact_id:$a}')" | jq -c '{message}' 2>/dev/null || true
wait_scan "$uid"; echo "  scans: $(scans "$uid")"
get config.json
api PUT /repositories/hf-staging/security -d '{"scan_enabled":true,"scan_on_upload":true}' | jq -c '{scan_on_upload}'
