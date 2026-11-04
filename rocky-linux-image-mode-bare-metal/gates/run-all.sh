#!/usr/bin/env bash
# make gates: the plan's verification gates as one verdict line per check (the e2e contract in
# CONTRIBUTING.md), after make all:
#   G6-G8  signing/verify.sh (keys, cosign signatures, build-host policy, repodata and RPM
#          signatures), one check per line it prints
#   G4/G5/G9  the VM sequence (make vm-clean vm-all), only with a read-write /dev/kvm;
#          without KVM it is BLOCKED(kvm): under TCG it takes hours
# Lines go to stdout and to out/gates/results.tsv (time, status, gate, check, why).
# Exit status 1 if any check FAILs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/out/gates"; mkdir -p "$G"; RESULTS="$G/results.tsv"
fails=0
verdict() { # STATUS GATE CHECK [WHY]
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "${4:-}" >> "$RESULTS"
  printf '%-12s %-4s %s%s\n' "$1" "$2" "$3" "${4:+: $4}"
  [[ $1 == FAIL ]] && fails=$((fails + 1)); return 0
}

# G6-G8 from signing/verify.sh: "verify: OK <what>" / "verify: FAIL <what>"
RELEASES="${RELEASES:-3 4}" "$ROOT/signing/verify.sh" > "$G/verify.log" 2>&1; vrc=$?
n=0
while IFS= read -r line; do
  [[ $line =~ ^verify:\ (OK|FAIL)\ +(.*)$ ]] || continue
  st=${BASH_REMATCH[1]} what=${BASH_REMATCH[2]} n=$((n + 1))
  case $what in
    *unsigned*|*rejects*|*admitted*) gate=G6 ;;
    cosign:*|*admits*)               gate=G7 ;;
    *)                               gate=G8 ;;
  esac
  if [[ $st == OK ]]; then verdict PASS $gate "$what"; else verdict FAIL $gate "$what" "see out/gates/verify.log"; fi
done < "$G/verify.log"
(( n > 0 )) || verdict FAIL G8 "signing/verify.sh printed no checks" "exit $vrc, see out/gates/verify.log"

# G4, G5, G9: the VM sequence
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  if make -C "$ROOT" vm-clean vm-all > "$G/vm-all.log" 2>&1; then
    verdict PASS G9 "install, boot, verify, unsigned upgrade refused, upgrade, rollback (make vm-all, KVM)"
  else
    verdict FAIL G9 "install, boot, verify, unsigned upgrade refused, upgrade, rollback (make vm-all, KVM)" "see out/gates/vm-all.log"
  fi
  make -C "$ROOT" vm-stop >/dev/null 2>&1 || true
else
  verdict "BLOCKED(kvm)" G9 "install, boot, verify, upgrade, rollback in a VM" "/dev/kvm is not read-write for $(id -un)"
fi
echo "gates: $(grep -c $'\tPASS\t' "$RESULTS") PASS, $(grep -c $'\tBLOCKED' "$RESULTS") BLOCKED, $fails FAIL; evidence in $G"
exit $(( fails > 0 ))
