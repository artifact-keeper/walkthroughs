#!/usr/bin/env bash
# G14 Allowlist: the lockfile is the allowlist. allowlist/from-lock.sh admits the
# conda packages of project/pixi.lock (name, exact version, subdir) on conda-virtual.
# Then (a) the virtual repodata, in all three encodings, carries exactly the lock's
# packages from the remote member plus every hosted record; (b) channeldata names
# nothing else; (c) a conda-forge package outside the lock is 404 through the
# virtual channel and `pixi add` reports it as not found; (d) the project still
# installs from the lock on build-isolated; (e) allowlist/off.sh restores the full
# merge. The gate always leaves the allowlist off (trap), as the demo runs with it off.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
G=G14; V=conda-virtual; LOCK="$ROOT/project/pixi.lock"
OUTSIDE="${OUTSIDE:-colorama}"; OUTSIDE_FILE="${OUTSIDE_FILE:-noarch/colorama-0.4.6-pyhd8ed1ab_1.conda}"
trap '"$ROOT/allowlist/off.sh" >/dev/null 2>&1' EXIT
CACHES=(ak-conda-g14-on ak-conda-g14-off ak-conda-g14-install)
podman volume rm -f "${CACHES[@]}" >/dev/null 2>&1

c=$(http GET "$U/api/v1/repositories/$V/allowlist" admin)
if [[ $c == 404 ]]; then
  for k in "a. repodata lists only the lock's remote packages" "b. channeldata" "c. package outside the lock not found" "d. project installs" "e. allowlist off restores the merge"; do
    blocked F20 $G "$k" "GET /api/v1/repositories/$V/allowlist: HTTP 404 (backend without #4576)"; done
  exit 0
fi
[[ -f "$LOCK" ]] || { fail $G "setup" "$LOCK missing (make lock)"; exit 0; }
"$ROOT/allowlist/from-lock.sh" --list "$LOCK" > "$SP_TMP/g14-lock.tsv"
if grep -qP "^$OUTSIDE\t" "$SP_TMP/g14-lock.tsv"; then fail $G "setup" "$OUTSIDE is in the lock; pick another OUTSIDE"; exit 0; fi

if out=$("$ROOT/allowlist/from-lock.sh" "$LOCK" 2>&1); then echo "$out"; pass $G "allowlist set from the lock ($(grep -c . "$SP_TMP/g14-lock.tsv") conda packages)"
else fail $G "allowlist/from-lock.sh" "$(tail -1 <<<"$out")"; exit 0; fi
"$ROOT/allowlist/show.sh" | head -6; echo "  ..."

# hosted members (not filtered) and the names they own
hosted=$(akcurl -fsS -H "$(admin_h)" "$U/api/v1/repositories/$V/members" | jq -r '.members[] | select(.member_repo_type != "remote") | .member_repo_key')
echo "hosted members of $V: $(echo $hosted)"
records() { jq -r '[(.packages // {}), (.["packages.conda"] // {})] | map(to_entries[]) | .[] | [.value.name, .value.version, .key] | @tsv' "$1" | sort; }

# (a) repodata, three encodings
ok_enc=1; ok_a=1; why=""
for sub in noarch linux-64; do
  http GET "$U/conda/$V/$sub/repodata.json" consumer >/dev/null; jq -S . "$SP_TMP/body" > "$SP_TMP/g14-rd.json"
  http GET "$U/conda/$V/$sub/repodata.json.zst" consumer >/dev/null; zstd -dqc "$SP_TMP/body" | jq -S . > "$SP_TMP/g14-rd.zst.json" || ok_enc=0
  http GET "$U/conda/$V/$sub/repodata.json.bz2" consumer >/dev/null; bzip2 -dc "$SP_TMP/body" | jq -S . > "$SP_TMP/g14-rd.bz2.json" || ok_enc=0
  cmp -s "$SP_TMP/g14-rd.json" "$SP_TMP/g14-rd.zst.json" && cmp -s "$SP_TMP/g14-rd.json" "$SP_TMP/g14-rd.bz2.json" || { ok_enc=0; echo "$sub: encodings differ"; }
  records "$SP_TMP/g14-rd.json" > "$SP_TMP/g14-virtual.tsv"
  : > "$SP_TMP/g14-hosted.tsv"
  for h in $hosted; do http GET "$U/conda/$h/$sub/repodata.json" admin >/dev/null; jq -S . "$SP_TMP/body" > "$SP_TMP/g14-h.json"; records "$SP_TMP/g14-h.json" >> "$SP_TMP/g14-hosted.tsv"; done
  sort -o "$SP_TMP/g14-hosted.tsv" "$SP_TMP/g14-hosted.tsv"
  cut -f1 "$SP_TMP/g14-hosted.tsv" | sort -u > "$SP_TMP/g14-hosted-names"
  # remote part of the merge = virtual records that are not hosted records
  comm -23 "$SP_TMP/g14-virtual.tsv" "$SP_TMP/g14-hosted.tsv" > "$SP_TMP/g14-remote.tsv"
  cut -f1,2 "$SP_TMP/g14-remote.tsv" | sort -u > "$SP_TMP/g14-remote-nv"
  # the lock's packages in this subdir whose names no hosted member owns
  awk -F'\t' -v s="$sub" -v hn="$(tr '\n' ' ' < "$SP_TMP/g14-hosted-names")" \
    'BEGIN {n = split(hn, a, " "); for (i = 1; i <= n; i++) h[a[i]] = 1} $3 == s && !($1 in h) {print $1"\t"$2}' \
    "$SP_TMP/g14-lock.tsv" | sort -u > "$SP_TMP/g14-lock-nv"
  awk -F'\t' -v s="$sub" '$3 == s {print $4}' "$SP_TMP/g14-lock.tsv" | sort > "$SP_TMP/g14-lock-files"
  missing_hosted=$(comm -23 "$SP_TMP/g14-hosted.tsv" "$SP_TMP/g14-virtual.tsv" | wc -l)
  missing_lock=$(comm -23 "$SP_TMP/g14-lock-files" <(cut -f3 "$SP_TMP/g14-virtual.tsv" | sort) | tr '\n' ' ')
  extra=$(comm -23 "$SP_TMP/g14-remote-nv" "$SP_TMP/g14-lock-nv" | tr '\t\n' '= ')
  absent=$(comm -13 "$SP_TMP/g14-remote-nv" "$SP_TMP/g14-lock-nv" | tr '\t\n' '= ')
  echo "$sub: $(wc -l < "$SP_TMP/g14-virtual.tsv") records ($(wc -l < "$SP_TMP/g14-remote.tsv") from the remote covering $(wc -l < "$SP_TMP/g14-remote-nv") name/version pairs, $(( $(wc -l < "$SP_TMP/g14-virtual.tsv") - $(wc -l < "$SP_TMP/g14-remote.tsv") )) hosted); lock: $(wc -l < "$SP_TMP/g14-lock-files") files"
  [[ -n "$extra" ]] && { ok_a=0; why+="$sub: not in the lock: ${extra:0:200}; "; }
  [[ -n "$absent" ]] && { ok_a=0; why+="$sub: lock name/version missing: ${absent:0:200}; "; }
  [[ -n "$missing_lock" ]] && { ok_a=0; why+="$sub: locked files missing: ${missing_lock:0:200}; "; }
  (( missing_hosted == 0 )) || { ok_a=0; why+="$sub: $missing_hosted hosted records missing; "; }
  cp "$SP_TMP/g14-virtual.tsv" "$SP_TMP/g14-virtual-$sub.tsv"
done
((ok_enc)) && pass $G "a. repodata.json, .zst and .bz2 of $V decode to the same document (noarch, linux-64)" || fail $G "a. repodata encodings agree"
((ok_a)) && pass $G "a. $V repodata: remote records are exactly the lock's name/version pairs, every locked file is listed, every hosted record is kept" \
  || fail $G "a. $V repodata matches the lock" "$why"

# (b) channeldata
http GET "$U/conda/$V/channeldata.json" consumer >/dev/null
jq -r '.packages | keys[]' "$SP_TMP/body" | sort -u > "$SP_TMP/g14-cd-names"
sort -u <(cut -f1 "$SP_TMP/g14-lock.tsv") "$SP_TMP/g14-hosted-names" > "$SP_TMP/g14-allowed-names"
for h in $hosted; do http GET "$U/conda/$h/channeldata.json" admin >/dev/null; jq -r '.packages | keys[]' "$SP_TMP/body"; done | sort -u >> "$SP_TMP/g14-allowed-names"
sort -u -o "$SP_TMP/g14-allowed-names" "$SP_TMP/g14-allowed-names"
leak=$(comm -23 "$SP_TMP/g14-cd-names" "$SP_TMP/g14-allowed-names" | tr '\n' ' ')
echo "channeldata.json: $(wc -l < "$SP_TMP/g14-cd-names") names; $OUTSIDE listed: $(grep -cx "$OUTSIDE" "$SP_TMP/g14-cd-names")"
[[ -z "$leak" ]] && pass $G "b. $V channeldata names only lock and hosted packages ($(wc -l < "$SP_TMP/g14-cd-names") names)" \
  || fail $G "b. channeldata leaks names outside the allowlist" "${leak:0:300}"

# (c) a conda-forge package outside the lock
c_forge=$(http GET "$U/conda/conda-forge/$OUTSIDE_FILE" consumer)
c=$(http GET "$U/conda/$V/$OUTSIDE_FILE" consumer); b=$(body | head -c 200)
echo "GET /conda/conda-forge/$OUTSIDE_FILE  $c_forge   (the remote itself is not filtered)"
echo "GET /conda/$V/$OUTSIDE_FILE  $c  $b"
[[ $c == 404 ]] && pass $G "c. $OUTSIDE (on conda-forge, not in the lock) is 404 through $V" || fail $G "c. $OUTSIDE download through $V" "HTTP $c $b"
W="$SP_TMP/g14-project"; rm -rf "$W"; mkdir -p "$W"; cp "$ROOT/project/pixi.toml" "$LOCK" "$W/"
add() { podman run --rm --network "$NET" -v "$1:/cache" -v "$W:/work:z" -w /work \
  -v "$TOKENS/consumer-auth.json:/run/secrets/a.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/a.json "$CLIENT" \
  pixi add --no-install "$OUTSIDE" 2>&1 | grep -v '^ WARN'; }
out=$(add ak-conda-g14-on); echo "$ pixi add --no-install $OUTSIDE      # allowlist on"; echo "$out" | tail -12
msg=$(tr -s ' \n│╰─▶├×' ' ' <<<"$out" | grep -oE "No candidates were found for $OUTSIDE[^.]*|$OUTSIDE[^.]*(cannot be found|not found|does not exist)[^.]*" | head -1)
if [[ -n "$msg" ]] && ! grep -q "^ *- conda: .*/$OUTSIDE-" "$W/pixi.lock"; then pass $G "c. pixi add $OUTSIDE: \"$msg\""
else fail $G "c. pixi add $OUTSIDE reports not found" "$(tail -2 <<<"$out" | tr '\n' ' ')"; fi

# (d) the project still installs from its lock, cold cache, isolated network
rm -rf "$ROOT/project/.pixi/envs"; t0=$(date +%s); s0=$SECONDS
out=$(NETWORK="$ISOLATED_NET" CACHE_VOLUME=ak-conda-g14-install "$ROOT/project/pixi-run.sh" install --locked 2>&1 | grep -v '^ WARN'); dt=$((SECONDS - s0))
echo "$out" | tail -2
access_since "$t0" | grep "/conda/$V/" > "$SP_TMP/g14-install.tsv"
n_ok=$(awk -F'\t' '$2 ~ /\.(conda|tar\.bz2)$/ && $3 == 200' "$SP_TMP/g14-install.tsv" | wc -l)
n_bad=$(awk -F'\t' '$3 != 200 && $3 != 304' "$SP_TMP/g14-install.tsv" | wc -l)
echo "$V requests during install: $(wc -l < "$SP_TMP/g14-install.tsv") ($n_ok package downloads 200, $n_bad other than 200/304)"
if grep -q 'environment has been installed' <<<"$out" && (( n_bad == 0 )); then pass $G "d. project installs with pixi install --locked through the allowlisted $V (build-isolated, cold cache, $n_ok packages from $V, $dt s)"
else fail $G "d. pixi install --locked through the allowlisted $V" "$(tail -2 <<<"$out" | tr '\n' ' ') non-200: $n_bad"; fi

# (e) off: the full merge comes back
"$ROOT/allowlist/off.sh"
c=$(http GET "$U/conda/$V/$OUTSIDE_FILE" consumer)
n=$(akcurl -fsS -H "Authorization: Bearer $(tok consumer)" "$U/conda/$V/linux-64/repodata.json.zst" | zstd -dqc | jq '(.["packages.conda"]|length) + (.packages|length)')
http GET "$U/conda/$V/channeldata.json" consumer >/dev/null; cd_n=$(jq '.packages | length' "$SP_TMP/body"); cd_o=$(jq --arg n "$OUTSIDE" '.packages | has($n)' "$SP_TMP/body")
echo "allowlist off: $OUTSIDE download HTTP $c; linux-64 records $n; channeldata $cd_n names, $OUTSIDE listed: $cd_o"
rm -f "$W/pixi.lock"; cp "$LOCK" "$W/"; cp "$ROOT/project/pixi.toml" "$W/"
out=$(add ak-conda-g14-off); echo "$ pixi add --no-install $OUTSIDE      # allowlist off"; echo "$out" | tail -3
got=$(grep -m1 -oE "^- conda: [^ ]*/$OUTSIDE-[^ ]*" "$W/pixi.lock" | cut -c10-)
if [[ $c == 200 && ${n:-0} -gt 100000 && $cd_o == true && -n "$got" ]]; then
  pass $G "e. allowlist off: full merge back ($n linux-64 records, $cd_n channeldata names), $OUTSIDE downloads (200) and pixi add locks $got"
else fail $G "e. allowlist off restores the merge" "download $c, $n records, channeldata has $OUTSIDE: $cd_o, locked: ${got:-none}"; fi
podman volume rm -f "${CACHES[@]}" >/dev/null 2>&1
