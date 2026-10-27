#!/usr/bin/env bash
# Build and publish the internal packages, as CI would, from the sandbox image:
#   acme-agent-tools 1.0.0 -> pypi-internal   (uv build, uv publish; ci-pypi token)
#   @acme/tickets-mcp 1.0.0 -> npm-internal   (npm publish; ci-npm token)
# Build dependencies (hatchling) resolve through pypi-virtual with the agent token.
# Re-running is safe: an existing version answers 409/403 and is left as is.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../registry/lib.sh"
run() { "$here/../sandbox/run.sh" "$@"; }
ci_pypi="$(cat "$TOKENS/ci-pypi.token")"; ci_npm="$(cat "$TOKENS/ci-npm.token")"

echo "== acme-agent-tools -> pypi-internal"
rm -rf "$here/acme-agent-tools/dist"
run -w "$here/acme-agent-tools" -- uv build --quiet
out=$(run -w "$here/acme-agent-tools" -- sh -c "uv publish --publish-url https://ak.internal/pypi/pypi-internal/ \
        --username ci --password '$ci_pypi' dist/* 2>&1" ) && echo "$out" | tail -2 || {
  echo "$out" | tail -3
  echo "$out" | grep -qiE '409|already exists|conflict' && echo "(already published)" || exit 1; }

echo "== @acme/tickets-mcp -> npm-internal"
out=$(run -w "$here/tickets-mcp" -- sh -c "printf '%s\n' 'registry=https://ak.internal/npm/npm-internal/' \
        '//ak.internal/npm/npm-internal/:_authToken=$ci_npm' > /tmp/ci.npmrc && npm publish --userconfig /tmp/ci.npmrc 2>&1") \
  && echo "$out" | grep -E '^\+|notice (name|version|total files)' || {
  echo "$out" | tail -3
  echo "$out" | grep -qiE 'E409|E403.*(exists|previously published)|cannot publish over' && echo "(already published)" || exit 1; }
