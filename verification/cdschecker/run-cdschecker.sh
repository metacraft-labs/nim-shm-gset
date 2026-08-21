#!/usr/bin/env bash
# Build and run every CDSChecker artifact, and CHECK the verdicts (design spec
# §4.5(a)). CDSChecker comes from this repo's pinned flake; see ../README.md.
#
#   just verify-cdschecker
#
# Each shipped build must report ZERO buggy executions. Each control build must
# report a NONZERO count — a clean control would mean the control proves
# nothing about whether the shipped ordering is load-bearing, so it is failed
# here rather than reported as a pass.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! command -v cdschecker-cc >/dev/null 2>&1; then
  echo "cdschecker not found. Run: just verify-cdschecker" >&2
  exit 127
fi

fail=0

buggy_count() {        # buggy_count <logfile>
  awk '/Number of buggy executions:/ { print $NF }' "$1"
}

run_case() {           # run_case <expect: clean|buggy> <label> <src> [cflags...]
  local expect="$1" label="$2" src="$3"; shift 3
  local bin="$work/$(basename "$src" .c).$$"
  if ! cdschecker-cc "$@" -o "$bin" "$here/$src" > "$work/cc.log" 2>&1; then
    echo "  [ERROR]  $label — compile failed"
    sed 's/^/           /' "$work/cc.log"
    fail=1
    return
  fi
  cdschecker "$bin" > "$work/run.log" 2>&1
  local n
  n="$(buggy_count "$work/run.log")"
  if [ -z "$n" ]; then
    echo "  [ERROR]  $label — CDSChecker produced no summary"
    sed 's/^/           /' "$work/run.log"
    fail=1
    return
  fi
  case "$expect" in
    clean)
      if [ "$n" -eq 0 ]; then echo "  [OK]     $label — 0 buggy executions"
      else echo "  [FAILED] $label — $n buggy executions, expected 0"; fail=1; fi ;;
    buggy)
      if [ "$n" -gt 0 ]; then echo "  [OK]     $label — $n buggy executions (the control MUST fail)"
      else echo "  [FAILED] $label — 0 buggy executions; the control is vacuous"; fail=1; fi ;;
  esac
}

echo "=============== CDSChecker (C11/C++11 atomics model checker) ==============="
run_case clean "slot-publish, shipped release/acquire"      slot-publish.c
run_case buggy "slot-publish, RELAXED control"              slot-publish.c -DRELAXED_SLOT
run_case clean "seal-vs-register, shipped seq_cst"          seal-vs-register.c

# The fourth case is NOT run, and this is a real gap rather than a formality.
#
# `seal-vs-register.c -DRELAXED_SEAL` makes CDSChecker abort — not report a bug,
# ABORT — inside its own machinery:
#
#   Program received signal SIGSEGV in mspace_malloc ()
#     #1 user_malloc (size=1048) at mymemory.cc:171
#     #2 Thread::operator new (size=1048) at threads-model.h:104
#     #3 ModelChecker::run () at model.cc:468
#   *** buffer overflow detected ***: terminated
#
# reproducible on a plain (non-Nix) build of upstream master too, at every
# bounding option (-m/-u/-e/-f/-x), and independent of the memory orders used
# (pure relaxed aborts identically). It is CDSChecker's 2014-era snapshotting
# allocator meeting a 2025 glibc, not something this repo's code causes: the
# OTHER control in this file (slot-publish, RELAXED) reports its bug correctly,
# so bug reporting per se works.
#
# AND IT IS AN ABORT, NOT A QUIET PASS — checked, because "the control skipped"
# and "the control passed" must never be confusable. `-b` (upper length bound)
# is the one option under which the binary exits 0, and only by truncation:
# -b2..-b16 finish 0 COMPLETE executions (1-4 redundant, nothing reaches the
# assertion), -b20 finishes 2, and -b30 and above abort again. The shipped
# seq_cst build, by contrast, explores 6 executions to completion. So there is
# no bounding under which this control both explores its state space and
# returns a verdict; a truncated "0 buggy executions" is not evidence of
# anything and is not reported as such. Note also that if this case were wired
# up as a run_case, the abort would trip the "produced no summary" branch and
# FAIL the runner — it could not degrade into a silent pass.
#
# WHAT COVERS IT INSTEAD, so nothing is left merely asserted:
#   * herd7, C11 language model, 4 models  -> ../litmus/reset-seal-vs-register-
#                                             RELAXED-control.litmus, "Sometimes"
#   * herd7, hardware models, all 3 archs  -> ../litmus/arch/SB-relacq.{AArch64,
#                                             RISCV,X86}.litmus, "Sometimes"
#   * GenMC, RC11, real core               -> `just verify-models`, safety
#                                             violation with a counterexample
#   * real x86-64 silicon                  -> ../core/shm_gset_reset_core.c
#                                             -DRELAXED_SEAL, `just verify-core`
echo "  [SKIPPED] seal-vs-register, RELAXED_SEAL control — upstream CDSChecker"
echo "            aborts in its own snapshot allocator on this program; see the"
echo "            comment in this script for the four artifacts that cover it."

echo
if [ "$fail" -eq 0 ]; then
  echo "[OK] 3 of 4 CDSChecker cases ran; every verdict matched its declared"
  echo "     expectation. 1 SKIPPED (upstream abort, covered elsewhere — above)."
else
  echo "[FAILED] some CDSChecker verdicts did not match"
fi
exit $fail
