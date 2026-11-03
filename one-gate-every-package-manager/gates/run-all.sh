#!/usr/bin/env bash
# The walkthrough's gates G1-G9 (docs plan.md). Each prints its evidence and one verdict per
# check: PASS, FAIL or BLOCKED(#issue). BLOCKED = the check depends on an Artifact Keeper fix
# that is not merged (listed in plan.md); it is reported, not counted as a failure.
# Needs `make all` first: the client logs in clients/out/{record,enforce}/ and out/preview.json
# are evidence. Exit status 1 if any check FAILs.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh" || exit 1
rm -rf "$GOUT"; mkdir -p "$GOUT"
CO="$ROOT/clients/out"
fails=0
count_fail() { fails=$(grep -c $'\tFAIL\t' "$RESULTS" 2>/dev/null || echo 0); }

# The known-bad fixtures: repository, cache path (regex for proxy-scans), exact probe path.
KB_GO='go-proxy|golang.org/x/text/@v/v0.3.0.zip|golang.org/x/text/@v/v0.3.0.zip'
KB_CARGO='cargo-proxy|api/v1/crates/smallvec/1.6.0/download|api/v1/crates/smallvec/1.6.0/download'
KB_NPM='npm-proxy|lodash-4.17.15.tgz|lodash/-/lodash-4.17.15.tgz'
# The OS packages' cache paths carry the version the distribution serves on the day of the
# run, so they are read back from the proxy-scan records of the record phase.
kb_apt() { proxy_scan_entry debian-proxy "pool/.*/$(head -1 "$ROOT/clients/known-bad/apt.txt")_" | jq -r .path; }
kb_apk() { proxy_scan_entry alpine-proxy "/$(head -1 "$ROOT/clients/known-bad/apk.txt")-[0-9]" | jq -r .path; }
KB_APT="debian-proxy|$(kb_apt | sed 's/[.+]/[&]/g')|$(kb_apt)"
KB_APK="alpine-proxy|$(kb_apk | sed 's/[.]/[.]/g')|$(kb_apk)"

# G1 the stack: five formats enforced, five proxies, every client reaches the registry ---
ev=()
formats=$(body_of "$(api GET /formats)" | jq -r '(if type=="array" then . else (.items // .formats) end)[] | select(.key as $k | ["go","cargo","npm","debian","alpine"] | index($k)) | "\(.key)=\(.scan_on_proxy)"' | sort | tr '\n' ' ')
ev+=("GET /api/v1/formats: $formats")
ok=1; [[ $formats == "alpine=enforced cargo=enforced debian=enforced go=enforced npm=enforced " ]] || ok=0
for p in 'go-proxy golang.org/x/text/@v/list' 'cargo-proxy index/sm/al/smallvec' 'npm-proxy lodash' 'debian-proxy dists/bookworm/InRelease' 'alpine-proxy v3.22/main/x86_64/APKINDEX.tar.gz'; do
  set -- $p; r=$("$PROBE" "$1" "$2"); ev+=("$1 $2: $r"); [[ $r == "HTTP 200"* ]] || ok=0
done
evidence G1 "${ev[@]}"
(( ok )) && pass G1 "five formats enforced; metadata of all five proxies served" || fail G1 "five formats enforced; metadata served" "see evidence"

# G2 record-only never withholds ---------------------------------------------------------
ev=(); ok=1
for t in go cargo npm apt apk; do
  e=$(log_exit "$CO/record/known-bad-$t.log"); ev+=("record phase, known-bad $t: exit ${e:-missing}"); [[ $e == 0 ]] || ok=0
  e=$(log_exit "$CO/record/baseline-$t.log"); ev+=("record phase, baseline $t: exit ${e:-missing}"); [[ $e == 0 ]] || ok=0
done
n=$(jq -r 'select(.state=="vulnerable")' "$ROOT/out/preview.json" 2>/dev/null | jq -s length)
ev+=("vulnerable verdicts recorded while record-only: $n (out/preview.json)")
(( n > 0 )) || ok=0
evidence G2 "${ev[@]}"
(( ok )) && pass G2 "record-only served every pull and recorded the verdicts" || fail G2 "record-only served every pull" "see evidence"

# G3 the preview predicted the refusals ---------------------------------------------------
ev=(); ok=1
rank=$(sev_rank "$THRESHOLD")
predicted=$(jq -r --argjson r "$rank" 'select(.state=="vulnerable") | select((.max_severity // "" | if .=="critical" then 5 elif .=="high" then 4 elif .=="medium" then 3 elif .=="low" then 2 else 1 end) >= $r) | "\(.repository)\t\(.path)"' "$ROOT/out/preview.json" | sort -u)
http GET "$U/api/v1/security/proxy-blocked?per_page=200" >/dev/null
blocked=$(body | jq -r '.items[] | "\(.repository_key)\t\(.path)"' | sort -u)
ev+=("predicted by policy/preview.sh (record phase): $(wc -l <<<"$predicted") file(s)" "$predicted" "" "GET /security/proxy-blocked now: $(wc -l <<<"$blocked") file(s)" "$blocked")
missing=$(comm -23 <(echo "$predicted") <(echo "$blocked"))
[[ -z $missing ]] || { ok=0; ev+=("predicted but not blocked:" "$missing"); }
evidence G3 "${ev[@]}"
(( ok )) && pass G3 "every file the preview marked is in the blocked list after enforcing" || fail G3 "preview matches enforcement" "see evidence"

# G4 enforcing refuses the known-bad pull of every format ----------------------------------
for spec in "$KB_GO" "$KB_CARGO" "$KB_NPM" "$KB_APT" "$KB_APK"; do
  IFS='|' read -r repo re path <<<"$spec"
  t=${repo%-proxy}; [[ $t == debian ]] && t=apt; [[ $t == alpine ]] && t=apk
  r=$("$PROBE" "$repo" "$path")
  entry=$(body_of "$(api GET "/repositories/$repo/security/proxy-scans?path=$path")" | jq -c '.items[0] // empty')
  summary=$(jq -r '"state=\(.state) severity=\(.max_severity) findings=\(.findings_count) cataloged=\(.components_cataloged) cves=\((.findings // [])[0:3] | map(.cve_id) | join(","))"' <<<"${entry:-{\}}")
  e=$(log_exit "$CO/enforce/known-bad-$t.log")
  evidence G4 "$t: client exit ${e:-missing}; probe $repo $path: $r" "   verdict: $summary"
  if [[ $r == "HTTP 403"*scan_blocked* && $e != 0 ]]; then pass G4 "$t: known-bad refused (403 scan_blocked), client failed"
  elif [[ $(jq -r .state <<<"${entry:-{\}}") == clean ]]; then fail G4 "$t: known-bad refused" "the fixture scanned clean: no advisory the scanner knows (see findings)"
  else fail G4 "$t: known-bad refused" "$r"; fi
done

# G5 the baselines still pass under enforcement ------------------------------------------
# Two runs per format: cold (right after enforcing, every file scanned inline on this pull)
# and warm (the same run again, verdicts stored). Both are reported.
for t in go cargo npm apt apk; do
  e=$(log_exit "$CO/enforce/baseline-$t.log"); w=$(log_exit "$CO/enforce-warm/baseline-$t.log")
  refused=$(grep -cE 'E423|423 Locked|403 Forbidden|Permission denied|scan_pending|scan_blocked' "$CO/enforce/baseline-$t.log" 2>/dev/null || true)
  evidence G5 "$t: cold run exit ${e:-missing} (${refused:-0} refusal line(s)); warm run exit ${w:-missing}"
  if [[ $e == 0 && $w == 0 ]]; then pass G5 "$t: baseline passes under fail_closed (cold and warm)"
  elif [[ $t == npm ]]; then
    r=$("$PROBE" npm-proxy '@types/node/-/node-22.15.3.tgz')
    cold423=$(grep -c 'E423' "$CO/enforce/baseline-npm.log" 2>/dev/null || true)
    evidence G5 "npm: @types/node tarball alone: $r" "$(grep -E 'E4[0-9]{2}' "$CO/enforce/baseline-npm.log" "$CO/enforce-warm/baseline-npm.log" | sed 's#.*/baseline-##' | head -4)"
    if [[ $r == "HTTP 423"*scan_pending* ]] && grep -q 'node-22.15.3.tgz - scan_pending' "$CO/enforce-warm/baseline-npm.log" 2>/dev/null; then
      blocked '#5149' G5 "npm: warm baseline passes under fail_closed" "@types/* tarballs never establish identity, 423 under fail_closed"
    else fail G5 "npm: warm baseline passes under fail_closed" "exit $w"; fi
    [[ $e == 0 ]] || fail G5 "npm: cold baseline passes under fail_closed" "exit $e: ${cold423:-0} 423 answer(s) on the cold install (inline scans over the 30 s budget, see findings F1)"
  else
    evidence G5 "$t baseline exit ${e:-missing}: $(grep -iE 'HTTP|error|E[0-9]{3}|403|423' "$CO/enforce/baseline-$t.log" | head -5)"
    fail G5 "$t: baseline passes under fail_closed" "exit ${e:-missing}"
  fi
done

# G6 what was refused is visible: blocked list, dashboard, queue, audit ---------------------
ev=(); ok=1
http GET "$U/api/v1/security/dashboard" >/dev/null; pb=$(body | jq -r .proxy_blocked)
http GET "$U/api/v1/security/proxy-blocked?per_page=200" >/dev/null; nb=$(body | jq '.items | length'); repos=$(body | jq -r '[.items[].repository_key] | unique | join(" ")')
http GET "$U/api/v1/admin/holds/policy-blocks?per_page=200" >/dev/null; nq=$(body | jq '[.items[] | select(.kind=="proxy-cache" or .source=="proxy-cache" or .source=="proxy_cache")] | length')
http GET "$U/api/v1/admin/audit?action=PROXY_SCAN_BLOCKED&per_page=200" >/dev/null
na=$(body | jq '(.items // .logs // []) | map(select(.action=="PROXY_SCAN_BLOCKED")) | length'); arepos=$(body | jq -r '(.items // .logs // []) | map(select(.action=="PROXY_SCAN_BLOCKED") | .details.repository) | unique | join(" ")')
ev+=("dashboard proxy_blocked=$pb" "proxy-blocked items=$nb repositories: $repos" "admin/holds/policy-blocks proxy-cache items=$nq" "audit PROXY_SCAN_BLOCKED rows=$na repositories: $arepos")
(( pb >= 1 && nb >= 1 && nq >= 1 && na >= 1 )) || ok=0
for k in go-proxy cargo-proxy npm-proxy; do [[ " $repos " == *" $k "* && " $arepos " == *" $k "* ]] || { ok=0; ev+=("$k missing from the blocked list or the audit"); }; done
evidence G6 "${ev[@]}"
(( ok )) && pass G6 "refusals are listed (blocked list, dashboard, queue) and audited" || fail G6 "refusals visible" "see evidence"

# G7 the hosted exception: acknowledge, then rescan -----------------------------------------
art=$(cat "$ROOT/out/vendored-artifact-id" 2>/dev/null)
if [[ -z $art ]]; then fail G7 "hosted exception" "run make exception first"; else
  http GET "$U/api/v1/security/artifacts/$art/scans" >/dev/null
  scans=$(body | jq -c '[(.items // .)[] | select(.status=="completed") | {scan_type, id, findings_count, created_at}] | sort_by(.created_at)')
  n=$(jq length <<<"$scans")
  latest=$(jq -r '.[-1]' <<<"$scans"); first=$(jq -r '.[0]' <<<"$scans")
  dl=$(http GET "$U/npm/npm-internal/lodash/-/lodash-4.17.15.tgz")
  evidence G7 "scans of the vendored lodash 4.17.15: $scans" "download now: HTTP $dl"
  # acknowledged rows per scan, oldest and newest
  acked() { http GET "$U/api/v1/security/scans/$1/findings?per_page=100" >/dev/null; body | jq '[(.items // .)[] | select(.is_acknowledged)] | length'; }
  unacked() { http GET "$U/api/v1/security/scans/$1/findings?per_page=100" >/dev/null; body | jq '[(.items // .)[] | select(.is_acknowledged | not)] | length'; }
  fa=$(acked "$(jq -r .id <<<"$first")"); lu=$(unacked "$(jq -r .id <<<"$latest")")
  evidence G7 "oldest scan: $fa acknowledged; newest scan: $lu unacknowledged"
  if (( n < 2 )); then fail G7 "acknowledged findings survive a rescan" "expected a second round of scans (make rescan)"
  elif (( fa > 0 && lu > 0 )) && [[ $dl == 403 ]]; then
    blocked '#5153' G7 "acknowledged findings survive a rescan" "the rescan wrote unacknowledged rows and the download is refused again"
  elif [[ $dl == 200 ]]; then pass G7 "acknowledged findings survive a rescan"
  else fail G7 "acknowledged findings survive a rescan" "download HTTP $dl, scans $scans"; fi
fi

# G8 the proxied exception: a crate refused for its bundled Cargo.lock ----------------------
r=$("$PROBE" cargo-proxy api/v1/crates/async-ctrlc/1.2.0/download)
entry=$(body_of "$(api GET '/repositories/cargo-proxy/security/proxy-scans?path=api/v1/crates/async-ctrlc/1.2.0/download')" | jq -c '.items[0] // empty')
own=$(jq -r '[(.findings // [])[] | select(.package_name=="async-ctrlc")] | length' <<<"${entry:-{\}}")
others=$(jq -r '[(.findings // [])[] | .package_name] | unique | join(",")' <<<"${entry:-{\}}")
evidence G8 "async-ctrlc 1.2.0: $r" "findings against async-ctrlc itself: $own; against other packages: $others"
if [[ $r == "HTTP 403"* && $own == 0 && -n $others ]]; then blocked '#5143' G8 "a crate is graded on its own coordinate, not its bundled Cargo.lock" "refused for $others"
elif [[ $r == "HTTP 200"* ]]; then pass G8 "a crate is graded on its own coordinate, not its bundled Cargo.lock"
else fail G8 "crate graded on its own coordinate" "$r"; fi

# G9 fails safely -------------------------------------------------------------------------
# (a) the generic download route refuses a scanning Remote
r=$(http GET "$U/api/v1/repositories/go-proxy/download/golang.org/x/text/@v/v0.21.0.zip"); b=$(body | jq -c . 2>/dev/null)
evidence G9 "generic route: HTTP $r $b"
[[ $r == 403 && $b == *scan_on_proxy_route_required* ]] && pass G9 "generic download route refuses a scanning Remote (403 scan_on_proxy_route_required)" || fail G9 "generic route refuses" "HTTP $r $b"
# (b) an Alpine branch that names no release is inconclusive: 423, never unscanned bytes
f=$(basename "$(kb_apk)"); r=$("$PROBE" alpine-proxy "latest-stable/main/x86_64/$f")
evidence G9 "alpine latest-stable/main/x86_64/$f: $r"
[[ $r == "HTTP 423"*scan_pending* ]] && pass G9 "fail_closed withholds a package whose release cannot be determined (alpine latest-stable: 423)" || fail G9 "inconclusive withheld" "$r"
# (c) a Debian Remote that has never served its Release: a base-release package is inconclusive
key=debian-proxy-fresh
http GET "$U/api/v1/repositories/$key" >/dev/null || true
if [[ $(http GET "$U/api/v1/repositories/$key") != 200 ]]; then
  http POST "$U/api/v1/repositories" -H 'Content-Type: application/json' -d "{\"key\":\"$key\",\"name\":\"Debian, never apt-updated (gate G9)\",\"format\":\"debian\",\"repo_type\":\"remote\",\"visibility\":\"public\",\"upstream_url\":\"https://deb.debian.org/debian\"}" >/dev/null
fi
THRESHOLD=$THRESHOLD "$ROOT/policy/mode.sh" fail_closed "$key" >/dev/null
# a package of the base release (no +deb12uN or ~bpo marker in its version): hello 2.10-3
basepkg='pool/main/h/hello/hello_2.10-3_amd64.deb'
r=$("$PROBE" "$key" "$basepkg")
evidence G9 "$key (no apt update yet) $basepkg: $r"
[[ $r == "HTTP 423"*scan_pending* ]] && pass G9 "a Debian Remote with no cached Release withholds a base-release package (423)" || fail G9 "fresh Debian remote withholds" "$r"
# (d) the instance lock: a repository administrator cannot weaken the policy
"$ROOT/policy/lock.sh" on go-proxy >/dev/null
pw="$TOKENS/repoadmin.password"
uid=$(body_of "$(api GET '/users?per_page=200')" | jq -r '(if type=="array" then . else .items end)[] | select(.username=="repoadmin") | .id')
if [[ -z $uid ]]; then
  (umask 077; echo "Ra$(openssl rand -hex 16)" > "$pw")
  uid=$(body_of "$(api POST /users -d "$(jq -nc --arg p "$(cat "$pw")" '{username:"repoadmin",email:"repoadmin@ak.internal",password:$p,display_name:"Repository admin of go-proxy (gate G9)",is_admin:false}')")" | jq -r '.user.id // .id')
  api POST /permissions -d "$(jq -nc --arg u "$uid" --arg r "$(repo_id go-proxy)" '{principal_type:"user",principal_id:$u,target_type:"repository",target_id:$r,actions:["admin","read","write"]}')" >/dev/null
fi
rjwt=$(akcurl -sS -X POST "$U/api/v1/auth/login" -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$(cat "$pw")" '{username:"repoadmin",password:$p}')" | jq -r .access_token)
weaken=$(akcurl -sS -o "$GOUT/body" -w '%{http_code}' -X PUT "$U/api/v1/repositories/go-proxy/security" -H "Authorization: Bearer $rjwt" -H 'Content-Type: application/json' -d '{"proxy_scan_action":"record_only"}'); wb=$(body | jq -c . 2>/dev/null)
tighten=$(akcurl -sS -o "$GOUT/body" -w '%{http_code}' -X PUT "$U/api/v1/repositories/go-proxy/security" -H "Authorization: Bearer $rjwt" -H 'Content-Type: application/json' -d '{"severity_threshold":"medium"}')
akcurl -sS -o /dev/null -X PUT "$U/api/v1/repositories/go-proxy/security" -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' -d "{\"proxy_scan_action\":\"fail_closed\",\"severity_threshold\":\"$THRESHOLD\",\"instance_locked\":true}"
locked=$(body_of "$(api GET /repositories/go-proxy/security)" | jq -r .config.instance_locked)
evidence G9 "go-proxy instance_locked=$locked; repoadmin sets record_only: HTTP $weaken $wb; repoadmin lowers the threshold to medium: HTTP $tighten (reset to $THRESHOLD)"
[[ $locked == true && $weaken == 403 && $tighten == 200 ]] && pass G9 "instance lock: a repository admin can tighten the policy but not weaken it" || fail G9 "instance lock" "locked=$locked weaken=$weaken tighten=$tighten"
# (e) a retry loop against a refused file writes at most two audit rows a minute: the first
# refusal at once, the repeats as one summary row when the 60 s window closes. Wait for it.
IFS='|' read -r repo re path <<<"$KB_NPM"
sleep 61   # let any window a previous pull of this file opened close first
since=$(date -u +%FT%TZ)
for _ in $(seq 12); do "$PROBE" "$repo" "$path" >/dev/null; done
sleep 65
http GET "$U/api/v1/admin/audit?action=PROXY_SCAN_BLOCKED&per_page=200&from=$since" >/dev/null
rows=$(body | jq -r --arg s "$since" '[(.items // [])[] | select(.action=="PROXY_SCAN_BLOCKED" and .details.path=="lodash-4.17.15.tgz" and ((.created_at | sub("\\.[0-9]+";"")) >= $s))] | sort_by(.created_at) | .[] | "attempts=\(.details.attempts) aggregated=\(.details.aggregated) at \(.created_at)"')
n=$(grep -c attempts <<<"$rows" || true)
evidence G9 "12 refused pulls of lodash 4.17.15 within a few seconds, counted 65 s later: $n audit row(s)" "$rows"
(( n >= 1 && n <= 2 )) && grep -q 'attempts=11 aggregated=true' <<<"$rows" && pass G9 "refusal audit is aggregated: a retry loop writes at most two rows a minute" || fail G9 "audit aggregation" "$n rows: $(tr '\n' ';' <<<"$rows")"
# (f) the refused file stays in the proxy cache listing and is refused on every read
http GET "$U/api/v1/repositories/npm-proxy/artifacts?per_page=500" >/dev/null
listed=$(body | jq -r '(.items // .)[] | select(.path | test("lodash-4.17.15.tgz")) | .path' | head -1)
r=$("$PROBE" "$repo" "$path")
evidence G9 "npm-proxy cache listing has lodash-4.17.15.tgz: ${listed:-no}; pull again: $r"
[[ -n $listed && $r == "HTTP 403"* ]] && pass G9 "a refused file stays listed in the cache and is refused from its stored verdict" || fail G9 "refused file listed and refused" "listed=${listed:-no} $r"

count_fail
echo
echo "gates: $(grep -c $'\tPASS\t' "$RESULTS") PASS, $(grep -c 'BLOCKED' "$RESULTS") BLOCKED, $fails FAIL; evidence in $GOUT"
exit $(( fails > 0 ))
