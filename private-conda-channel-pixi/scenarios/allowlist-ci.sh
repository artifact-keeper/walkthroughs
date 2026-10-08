#!/usr/bin/env bash
# The allowlist CI job: what runs when a pull request changes a project's dependencies.
#
#   lock    pixi lock in PROJECT_DIR against the UNFILTERED twin of conda-virtual
#           (SOLVE_CHANNEL, default https://ak.internal/conda/scn-virtual-ci: the same members,
#           conda-internal then conda-forge, with no allowlist). A pixi mirror sends
#           conda-virtual's requests there. WORKAROUND (artifact-keeper#4580): AK's repodata
#           carries a host-relative info.base_url ("/conda/scn-virtual-ci/<subdir>/"), so pixi
#           writes the twin's URLs into the lock. They are rewritten to conda-virtual's (same
#           members, same files, same sha256); check then refuses any other URL. Why a twin and not "turn the
#           allowlist off, lock, turn it on": conda-virtual is shared, and switching it off
#           opens all of conda-forge to every consumer for the length of the solve.
#   check   the lock names no host other than ak.internal; prints what the PR adds/removes
#           compared with the allowlist in force
#   apply   PUT the allowlist of conda-virtual from the lock (allowlist/from-lock.sh). The
#           list is one per virtual channel: pass every consumer's lock (EXTRA_LOCKS) and the
#           list is their union. Run this step on merge, not on the pull request.
#   verify  pixi install --locked through conda-virtual itself (the client image's own config),
#           cold cache: the allowlisted channel serves everything the lock needs
#
# Usage: scenarios/allowlist-ci.sh [lock|check|apply|verify|all] PROJECT_DIR    (default all)
# Env:   SOLVE_CHANNEL, SOLVE_AUTH (RATTLER_AUTH_FILE for the solve; default the scn-reader
#        token), EXTRA_LOCKS (space-separated other pixi.lock files for the union),
#        CACHE_VOLUME (default: a fresh scn-ci-<step> volume). The apply step uses the admin
#        token; a real CI job would hold a token that may write this one allowlist.
# Exit:  0 when every step passed; the failing step's message otherwise.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
STEP=all; [[ $# -ge 2 ]] && { STEP=$1; shift; }
DIR=$(cd "${1:?usage: $0 [lock|check|apply|verify|all] PROJECT_DIR}" && pwd)
SOLVE_CHANNEL=${SOLVE_CHANNEL:-$AK_URL/conda/scn-virtual-ci}
SOLVE_AUTH=${SOLVE_AUTH:-$SCN_TOKENS/scn-reader-auth.json}
say() { echo "allowlist-ci: $*"; }
run_pixi() { # CONFIG|"" VOLUME AUTH args...
  local cfg=$1 vol=$2 auth=$3; shift 3; local C=()
  [[ -n $cfg ]] && C=(-v "$cfg:/etc/pixi/config.toml:ro,z")
  podman volume rm -f "$vol" >/dev/null 2>&1 || true
  podman run --rm --network "$NET" -v "$vol:/cache" -v "$DIR:/work:z" -w /work "${C[@]}" \
    -v "$auth:/run/secrets/rattler-auth.json:ro,z" -e RATTLER_AUTH_FILE=/run/secrets/rattler-auth.json \
    "$CLIENT" pixi "$@" 2>&1 | grep -v '^ WARN'
  return "${PIPESTATUS[0]}"
}
union_lock() { # -> path of a lock-shaped file with every conda entry of DIR/pixi.lock and EXTRA_LOCKS
  local u="$WORK/allowlist-ci-union.lock" l
  { echo "packages:"; for l in "$DIR/pixi.lock" ${EXTRA_LOCKS:-}; do sed -n '/^packages:/,$ p' "$l" | grep '^- conda: '; done | sort -u; } > "$u"
  echo "$u"
}
do_lock() {
  local cfg="$WORK/allowlist-ci-pixi-config.toml"
  cat > "$cfg" <<TOML
# allowlist-ci.sh: solve against the unfiltered twin; the lock keeps conda-virtual's URLs
tls-root-certs = "system"
[mirrors]
"$AK_URL/conda/conda-virtual" = ["$SOLVE_CHANNEL"]
"https://conda.anaconda.org/conda-forge" = ["$AK_URL/conda/conda-forge"]
[pypi-config]
index-url = "$AK_URL/pypi/pypi-remote/simple"
TOML
  say "lock: pixi lock against $SOLVE_CHANNEL (as conda-virtual)"
  run_pixi "$cfg" "${CACHE_VOLUME:-scn-ci-lock}" "$SOLVE_AUTH" lock | tail -2
  local from="${SOLVE_CHANNEL%/}/" to="$AK_URL/conda/conda-virtual/" n
  n=$(grep -cF -- "$from" "$DIR/pixi.lock" || true)
  if (( n > 0 )); then sed -i "s|$from|$to|g" "$DIR/pixi.lock"; say "lock: rewrote $n URLs $from -> $to (#4580 workaround)"; fi
}
do_check() {
  local bad; bad=$(sed -n '/^packages:/,$ p' "$DIR/pixi.lock" | grep -E '^- (conda|pypi): ' |
    grep -vE "^- conda: $AK_URL/conda/(conda-virtual|conda-internal)/|^- pypi: $AK_URL/pypi/" || true)
  [[ -z $bad ]] || { say "check: FAILED, the lock names URLs outside conda-virtual, conda-internal and pypi on $AK_HOST:"; echo "$bad" | head -5; return 1; }
  "$ROOT/allowlist/from-lock.sh" --list "$(union_lock)" | cut -f1,2 | sort -u > "$WORK/allowlist-ci.want"
  "$ROOT/allowlist/show.sh" 2>/dev/null | tail -n +2 | awk '{print $1"\t"$2}' | sort -u > "$WORK/allowlist-ci.have" || true
  say "check: lock ok ($(grep -c '^- conda: ' "$DIR/pixi.lock") conda packages, all on conda-virtual or conda-internal)"
  comm -23 "$WORK/allowlist-ci.want" "$WORK/allowlist-ci.have" | sed 's/^/allowlist-ci:   + /; s/\t/ /'
  comm -13 "$WORK/allowlist-ci.want" "$WORK/allowlist-ci.have" | sed 's/^/allowlist-ci:   - /; s/\t/ /'
}
do_apply() { say "apply: $("$ROOT/allowlist/from-lock.sh" "$(union_lock)" | tail -1 | sed 's/^allowlist: //')"; }
do_verify() {
  say "verify: pixi install --locked through conda-virtual (cold cache)"
  rm -rf "$DIR/.pixi"
  run_pixi "" "${CACHE_VOLUME:-scn-ci-verify}" "$TOKENS/consumer-auth.json" install --locked | tail -1
}
case $STEP in
  lock) do_lock ;; check) do_check ;; apply) do_apply ;; verify) do_verify ;;
  all) do_lock && do_check && do_apply && do_verify ;;
  *) echo "usage: $0 [lock|check|apply|verify|all] PROJECT_DIR" >&2; exit 2 ;;
esac
