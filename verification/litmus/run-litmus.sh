#!/usr/bin/env bash
# Run every nim-shm-gset litmus test under herd7 and CHECK each result against
# the expectation the test file declares (design spec §4.5(a)).
#
# herd7 comes from THIS repo's pinned flake (see ../../flake.nix), not from the
# mutable system flake registry:
#
#   just verify-litmus                 # the blessed entry point
#   nix develop ..#  --command verification/litmus/run-litmus.sh
#
# TWO TIERS, and the difference is not cosmetic — it is the difference between
# "the LANGUAGE guarantees it" and "the HARDWARE guarantees it".
#
#  1. ./*.litmus are `C` litmus tests. herd7 checks a C test against a C11
#     LANGUAGE model (c11_partialSC.cat and friends). It CANNOT check one
#     against aarch64.cat / riscv.cat / x86tso.cat: a cat model is tied to one
#     architecture and herd7 rejects the mismatch outright. A C11 verdict is the
#     stronger statement for the SHIPPED orderings — Forbidden under C11 means
#     no conforming implementation on any target may permit it — but it cannot
#     distinguish "x86 hides this bug" from "ARM exposes it", which is the whole
#     point of the -RELAXED-control pairs.
#
#  2. ./arch/*.litmus are hand-written AArch64 / RISC-V / x86-64 ASSEMBLY
#     translations of the same shapes, each lowered the way a C compiler lowers
#     the corresponding C11 order. These are what carry the per-architecture
#     claim, and in particular the ARMv8 claim that qemu-user cannot make.
#
# EXPECTATIONS, derived from the file name and checked here rather than eyeballed:
#   *-RELAXED-control / *-CONTROL  -> herd7 must report "Sometimes" (ALLOWED)
#   everything else                -> herd7 must report "Never"     (FORBIDDEN)
#
# A control that comes out Forbidden is as much a failure as a shipped test that
# comes out Allowed: it would mean the control proves nothing about whether the
# shipped ordering is load-bearing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v herd7 >/dev/null 2>&1; then
  echo "herd7 not found. Run: just verify-litmus" >&2
  exit 127
fi

# The C11 model family. c11_partialSC is herd7's default for C tests; the others
# are re-run because they disagree about SC-fence subtleties, and agreement
# across all four is worth more than a single verdict.
c_models=("${SHM_GSET_C11_MODELS:-c11_partialSC.cat c11_orig.cat c11_simp.cat rc11.cat}")

fail=0
checked=0

check() {              # check <expect: Never|Sometimes> <label> <herd7 args...>
  local expect="$1" label="$2"; shift 2
  local out rc
  out="$(herd7 "$@" 2>&1)"; rc=$?
  local got
  got="$(printf '%s\n' "$out" | awk '/^Observation/ { print $3 }')"
  checked=$((checked + 1))
  if [ "$rc" -ne 0 ] || [ -z "$got" ]; then
    echo "  [ERROR]  $label — herd7 exit $rc, no Observation line"
    printf '%s\n' "$out" | sed 's/^/           /'
    fail=1
    return
  fi
  if [ "$got" = "$expect" ]; then
    echo "  [OK]     $label — $got (expected $expect)"
  else
    echo "  [FAILED] $label — $got, EXPECTED $expect"
    printf '%s\n' "$out" | sed 's/^/           /'
    fail=1
  fi
}

# Read the expectation off the test's OWN declared name (line 1, "<ARCH> <name>")
# rather than off the file name, so renaming a file cannot silently flip what it
# is checked against.
expectation_for() {    # expectation_for <path>
  local name
  name="$(head -1 "$1" | awk '{ print $2 }')"
  case "$name" in
    *RELAXED-control | *CONTROL) echo Sometimes ;;
    *) echo Never ;;
  esac
}

echo "=============== tier 1: C11 language model (arch-independent) ==============="
for m in ${c_models[@]}; do
  echo "--- herd7 -model $m ---"
  for f in "$here"/*.litmus; do
    check "$(expectation_for "$f")" "$(basename "$f" .litmus) [$m]" -model "$m" "$f"
  done
done

echo
echo "=============== tier 2: per-architecture hardware models ==============="
echo "(herd7 picks the arch's default cat model from the test's own header:"
echo " AArch64 -> aarch64.cat, RISCV -> riscv.cat, X86 -> x86tso.cat)"
for f in "$here"/arch/*.litmus; do
  [ -e "$f" ] || continue
  check "$(expectation_for "$f")" "$(basename "$f" .litmus)" "$f"
done

echo
if [ "$fail" -eq 0 ]; then
  echo "[OK] $checked litmus checks, every result matched its declared expectation"
else
  echo "[FAILED] some litmus results did not match their declared expectation"
fi
exit $fail
