#!/usr/bin/env bash
# The baseline: what each package manager fetches on an ordinary day, through the registry.
# Download only; nothing is installed into the container image or executed.
#
#   clients/baseline.sh [go|cargo|npm|apt|apk ...]     default: all five
#
# Output goes to clients/out/baseline-<tool>.log, with the exit status in the last line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="$here/out"; mkdir -p "$OUTDIR"
tools=("$@"); [[ ${#tools[@]} -gt 0 ]] || tools=(go cargo npm apt apk)
rc=0
for t in "${tools[@]}"; do
  log="$OUTDIR/baseline-$t.log"; : > "$log"
  # A copy of the project, so lockfiles and node_modules never land in the repository;
  # the lockfile the client wrote is kept in clients/out/ as evidence.
  proj=$(mktemp -d); cp -r "$here/baseline/$t/." "$proj/"
  start=$SECONDS
  case $t in
    go)    "$here/run.sh" go -w "$proj" -- go mod download -x; cp "$proj/go.sum" "$OUTDIR/baseline-go.sum" 2>/dev/null ;;
    cargo) "$here/run.sh" cargo -w "$proj" -- cargo fetch; cp "$proj/Cargo.lock" "$OUTDIR/baseline-Cargo.lock" 2>/dev/null ;;
    npm)   "$here/run.sh" npm -w "$proj" -- npm install --loglevel http; cp "$proj/package-lock.json" "$OUTDIR/baseline-package-lock.json" 2>/dev/null ;;
    apt)   CLIENT_ARGS="-v $here/baseline/apt/packages.txt:/etc/ak-packages:ro,z" \
             "$here/run.sh" apt -- sh -c 'apt-get update && apt-get download $(cat /etc/ak-packages)' ;;
    apk)   CLIENT_ARGS="-v $here/baseline/apk/packages.txt:/etc/ak-packages:ro,z" \
             "$here/run.sh" apk -- sh -c 'apk fetch --no-progress $(cat /etc/ak-packages)' ;;
    *) echo "baseline.sh: unknown tool $t" >&2; rc=2; continue ;;
  esac > >(tee -a "$log") 2>&1
  status=$?
  echo "baseline $t: exit $status in $((SECONDS - start))s" | tee -a "$log"
  (( status == 0 )) || rc=1
  rm -rf "$proj"
done
exit $rc
