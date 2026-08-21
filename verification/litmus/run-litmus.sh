#!/usr/bin/env bash
# Run every nim-shm-gset litmus test under herd7 for each hardware memory model
# (design spec §4.5(a)). herd7 (herdtools7) is NOT in this repo's dev shell/pin,
# so this is the blessed way to run the authored tests once the tool is present:
#
#   nix shell nixpkgs#herdtools7 --command verification/litmus/run-litmus.sh
#
# (At the time of authoring, `nixpkgs#herdtools7` / `#herd7` do not resolve in
# the pinned nixpkgs — see verification/README.md. Author-not-run until then.)
#
# For each shipped-ordering test the `exists` clause must be FORBIDDEN ("Never")
# on every model. The *-RELAXED-control tests must be ALLOWED ("Sometimes") —
# that is the whole point: they show the shipped ordering is load-bearing.
#
# Two different expectations among the controls, and the difference matters:
#   * the MESSAGE-PASSING controls (slot-publish, reset-rearm-publish) are
#     allowed on a WEAK model (aarch64/riscv) and may still be forbidden on
#     x86-TSO — the classic "passes on x86, faults on Apple silicon" trap;
#   * reset-seal-vs-register-RELAXED-control is a STORE-BUFFER shape and is
#     allowed on EVERY model INCLUDING x86. That is why the seal/registry
#     handshake is the one sequentially-consistent pair in the library, and it
#     is also reproducible on real x86-64 hardware — see
#     ../core/shm_gset_reset_core.c built with -DRELAXED_SEAL.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
models=("${@:-x86 aarch64 riscv}")

if ! command -v herd7 >/dev/null 2>&1; then
  echo "herd7 not found. Run under: nix shell nixpkgs#herdtools7 --command $0" >&2
  exit 127
fi

fail=0
for m in ${models[@]}; do
  echo "================= herd7 -model $m ================="
  for f in "$here"/*.litmus; do
    echo "--- $(basename "$f") ---"
    herd7 -model "$m" "$f" || fail=1
  done
done
exit $fail
