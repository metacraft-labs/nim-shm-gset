#!/usr/bin/env bash
# Cross-compile the C11 atomics core for aarch64 and run it under qemu-aarch64
# (design spec §4.5 ARM64 arm). IMPORTANT HONESTY CAVEAT: qemu-user does NOT
# faithfully reproduce ARMv8 weak-memory relaxations — it is a FUNCTIONAL check
# (aarch64 ABI / layout / compile correctness), NOT a weak-memory proof. Real
# weak-memory coverage needs real ARM hardware, or the herd7 litmus tests
# (../litmus) and a GenMC run of this same core.
#
# There is no aarch64 Nim toolchain in the dev shell, so only the C11 core (not
# the Nim tests) is cross-built here. Run:
#   nix shell nixpkgs#pkgsCross.aarch64-multiplatform.buildPackages.gcc \
#             nixpkgs#pkgsCross.aarch64-multiplatform.glibc \
#     --command verification/core/build-aarch64-qemu.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cc=aarch64-unknown-linux-gnu-gcc
out=/tmp/shm_set_core_aarch64
iters="${NITER:-2000}"

if ! command -v "$cc" >/dev/null 2>&1; then
  echo "aarch64 cross-gcc not found; run under the nix shell in this script's header." >&2
  exit 127
fi

echo "== cross-compiling shm_set_core for aarch64 (dynamic) =="
"$cc" -std=c11 -O2 -pthread -DSTANDALONE -DNITER="$iters" "$here/shm_set_core.c" -o "$out"
file "$out" | head -1

glibc="$(dirname "$(dirname "$("$cc" -print-file-name=libc.so.6)")")"
echo "== running under qemu-aarch64 (FUNCTIONAL only — not weak-memory) =="
QEMU_LD_PREFIX="$glibc" qemu-aarch64 -L "$glibc" "$out"
echo "[OK] aarch64 functional run complete (qemu-user; NOT a weak-memory proof)"
