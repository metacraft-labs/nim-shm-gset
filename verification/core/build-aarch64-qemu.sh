#!/usr/bin/env bash
# Cross-compile the C11 atomics core for aarch64 and run it under qemu-aarch64
# (design spec §4.5 ARM64 arm). IMPORTANT HONESTY CAVEAT: qemu-user does NOT
# faithfully reproduce ARMv8 weak-memory relaxations — it is a FUNCTIONAL check
# (aarch64 ABI / layout / compile correctness), NOT a weak-memory proof. Real
# weak-memory coverage needs real ARM hardware, or the ARMv8 litmus tests
# (../litmus/arch/*.AArch64.litmus, RUN and green) and the GenMC/RC11 run of this
# same core (`just verify-models`). Both are wired now; see ../README.md, "The
# ARM64 requirement", for what they do and do not settle.
#
# There is no aarch64 Nim toolchain in the dev shell, so only the C11 core (not
# the Nim tests) is cross-built here. Run:
#   just verify-aarch64
# which supplies the cross toolchain and qemu from this repo's PINNED flake:
#   nix shell .#aarch64-cross-env --command verification/core/build-aarch64-qemu.sh
# (`nix shell`, not `nix develop`: a devShell exports NIX_CFLAGS_COMPILE with
#  -isystem pointing at the NATIVE glibc, which the cross gcc wrapper honours and
#  then dies on `gnu/stubs-32.h: No such file or directory`.)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cc=aarch64-unknown-linux-gnu-gcc
out=/tmp/shm_gset_core_aarch64
iters="${NITER:-2000}"

if ! command -v "$cc" >/dev/null 2>&1; then
  echo "aarch64 cross-gcc not found; run under the nix shell in this script's header." >&2
  exit 127
fi

glibc="$(dirname "$(dirname "$("$cc" -print-file-name=libc.so.6)")")"

run_core() {
  src="$1"; bin="$2"; shift 2
  echo "== cross-compiling $(basename "$src") for aarch64 (dynamic) $* =="
  "$cc" -std=c11 -O2 -pthread -DSTANDALONE -DNITER="$iters" "$@" "$src" -o "$bin" || exit 1
  file "$bin" | head -1
  echo "== running under qemu-aarch64 (FUNCTIONAL only — not weak-memory) =="
  QEMU_LD_PREFIX="$glibc" qemu-aarch64 -L "$glibc" "$bin"
}

run_core "$here/shm_gset_core.c" "$out"
# HM-2: the reset/recycling core, plus its RELAXED_SEAL control. Note that the
# control is expected to report ZERO straddles here: qemu-user does not
# reproduce ARM's store buffer, so the control only demonstrates its point on
# real hardware (see ../README.md for the x86-64 numbers) or under herd7.
run_core "$here/shm_gset_reset_core.c" "${out}_reset"
run_core "$here/shm_gset_reset_core.c" "${out}_reset_relaxed" -DRELAXED_SEAL
echo "[OK] aarch64 functional run complete (qemu-user; NOT a weak-memory proof)"
