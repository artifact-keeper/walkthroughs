#!/usr/bin/env bash
# Pull one package with a published advisory through each package manager, with the real
# client, exactly as a build would. Download only: nothing is installed or executed.
#
#   clients/known-bad.sh [go|cargo|npm|apt|apk ...]      default: all five
#
# The packages (see docs plan.md, "Known-bad fixtures"):
#   go     golang.org/x/text v0.3.0         CVE-2020-14040, CVE-2021-38561 (high); graded as itself (#4952)
#   cargo  smallvec 0.6.9                   CVE-2019-15551 (critical)
#   npm    lodash 4.17.15                   CVE-2020-8203, CVE-2021-23337 (high)
#   apt    the bookworm package named in clients/known-bad/apt.txt
#   apk    the v3.22 package named in clients/known-bad/apk.txt
# Each run writes clients/out/known-bad-<tool>.log; the exit status of the client is in
# the last line. A refused pull is the expected result once the gate enforces.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$here/out"; mkdir -p "$OUTDIR"
tools=("$@"); [[ ${#tools[@]} -gt 0 ]] || tools=(go cargo npm apt apk)
rc=0
for t in "${tools[@]}"; do
  log="$OUTDIR/known-bad-$t.log"; : > "$log"
  proj=$(mktemp -d); start=$SECONDS
  case $t in
    go)    printf 'module example.com/legacy\n\ngo 1.24\n' > "$proj/go.mod"
           "$here/run.sh" go -w "$proj" -- go mod download -x golang.org/x/text@v0.3.0 ;;
    cargo) mkdir -p "$proj/src"; : > "$proj/src/lib.rs"
           printf '[package]\nname = "legacy"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nsmallvec = "=0.6.9"\n' > "$proj/Cargo.toml"
           "$here/run.sh" cargo -w "$proj" -- cargo fetch ;;
    npm)   "$here/run.sh" npm -w "$proj" -- npm pack lodash@4.17.15 --loglevel http
           cp "$proj"/lodash-4.17.15.tgz "$OUTDIR/" 2>/dev/null ;;
    apt)   CLIENT_ARGS="-v $here/known-bad/apt.txt:/etc/ak-packages:ro,z" \
             "$here/run.sh" apt -- sh -c 'apt-get update -qq && apt-get download $(cat /etc/ak-packages)' ;;
    apk)   CLIENT_ARGS="-v $here/known-bad/apk.txt:/etc/ak-packages:ro,z" \
             "$here/run.sh" apk -- sh -c 'apk fetch --no-progress $(cat /etc/ak-packages)' ;;
    *) echo "known-bad.sh: unknown tool $t" >&2; rc=2; continue ;;
  esac > >(tee -a "$log") 2>&1
  status=$?
  echo "known-bad $t: exit $status in $((SECONDS - start))s" | tee -a "$log"
  (( status == 0 )) || rc=1
  rm -rf "$proj"
done
exit $rc
