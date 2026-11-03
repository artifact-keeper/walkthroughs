#!/usr/bin/env bash
# The exception that has nowhere to go, proxied side. async-ctrlc 1.2.0 (a dependency of
# taplo-cli) ships its author's Cargo.lock inside the .crate; the scanner grades every
# entry of that lockfile, and the crate is refused for packages its consumers never
# install (#5143). A proxied file has no acknowledgement (#5152): the findings can be read,
# rescanned, and that is all.
#
#   exception/proxied.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../policy/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; mkdir -p "$ROOT/out"
proj=$(mktemp -d); trap 'rm -rf "$proj"' EXIT
mkdir -p "$proj/src"; : > "$proj/src/lib.rs"
printf '[package]\nname = "tooling"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nasync-ctrlc = "=1.2.0"\n' > "$proj/Cargo.toml"
echo "proxied: cargo fetch of a project depending on async-ctrlc 1.2.0"
"$ROOT/clients/run.sh" cargo -w "$proj" -- cargo fetch 2>&1 | tee "$ROOT/out/proxied-cargo-fetch.log" || true
echo "proxied: the registry's answer:"
"$ROOT/clients/probe.sh" cargo-proxy api/v1/crates/async-ctrlc/1.2.0/download
echo "proxied: what the verdict is made of (proxy-scan record, findings by component):"
body_of "$(api GET '/repositories/cargo-proxy/security/proxy-scans?path=api/v1/crates/async-ctrlc/1.2.0/download')" \
  | jq -r '.items[] | "  state=\(.state) severity=\(.max_severity) findings=\(.findings_count) cataloged=\(.components_cataloged)", ((.findings // [])[] | "    \(.severity)\t\(.cve_id)\t\(.package_name)@\(.package_version)\tfixed=\(.fixed_version)")' \
  | column -t -s $'\t' | tee "$ROOT/out/proxied-findings.txt"
echo "proxied: the crate's own bundled lockfile is where those packages come from (the registry"
echo "proxied: refuses the bytes, so this reads them from the upstream, list-only, nothing is built):"
if curl -sSL --max-time 60 https://static.crates.io/crates/async-ctrlc/async-ctrlc-1.2.0.crate -o "$proj/x.crate" 2>/dev/null && tar -tzf "$proj/x.crate" | grep -q Cargo.lock; then
  echo "    $(tar -tzf "$proj/x.crate" | grep Cargo.lock)"
  tar -xzOf "$proj/x.crate" 'async-ctrlc-1.2.0/Cargo.lock' | grep -A1 -E 'name = "(crossbeam-deque|crossbeam-utils|futures-task|nix)"' | grep -v '^--' | paste - - | sed 's/^/    /'
else
  echo "    (upstream not reachable from this host; see the issue for the lockfile listing)"
fi
