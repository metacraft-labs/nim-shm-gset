#!/usr/bin/env bash
# rr chaos-mode record + deterministic replay of the multi-process fork oracle
# (design spec §4.5(f)). rr serialises the whole process tree onto a single core
# and, in chaos mode (`-h`), randomises the scheduler to surface rare
# interleavings a native run would take ages to hit; every recorded run still
# asserts the ground-truth oracle `snapshot == union(intended)` internally, and
# one trace is then replayed deterministically to prove reproducibility.
#
# rr needs a hardware CPU-cycle performance counter. On Intel hybrid (P/E-core)
# parts rr's PMU probe fails unless the tracee is pinned to a single core, so we
# pass `--bind-to-cpu` (harmless on non-hybrid machines). Override the core with
# RR_BIND_CPU and the iteration count with RR_CHAOS_ITERS.
# No `set -e`: rr exit codes are captured and checked explicitly below (a
# command-substitution failure under `set -e` would abort before we can inspect
# $?). `pipefail`/`-u` are kept.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
bind_cpu="${RR_BIND_CPU:-0}"
iters="${RR_CHAOS_ITERS:-5}"
soak_secs="${SHM_SET_SOAK_SECONDS:-1}"
nim_flags="--hints:off --threads:on --warning:BareExcept:off --path:$root/src"

bin="$(mktemp -u /tmp/shmset-rr-soak.XXXXXX)"
trace_dir="$(mktemp -d /tmp/shmset-rr-trace.XXXXXX)"
export _RR_TRACE_DIR="$trace_dir"
cleanup() { rm -rf "$trace_dir" "$bin"; }
trap cleanup EXIT

echo "== building fork-oracle soak harness =="
if ! nim c $nim_flags -o:"$bin" "$root/tests/test_shm_set_soak.nim"; then
  echo "FAIL: nim build failed" >&2; exit 1
fi

echo "== rr chaos record x$iters (SHM_SET_SOAK_SECONDS=$soak_secs, cpu=$bind_cpu) =="
for i in $(seq 1 "$iters"); do
  echo "-- chaos record iteration $i --"
  out="$(SHM_SET_SOAK_SECONDS="$soak_secs" \
    rr record -h --bind-to-cpu="$bind_cpu" -o "$trace_dir/trace$i" "$bin" 2>&1)"
  rc=$?
  echo "$out" | grep -E "OK|soak|Assert|Error|FAIL" || true
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: rr record iteration $i exited $rc" >&2
    echo "$out" | tail -20 >&2
    exit 1
  fi
done

echo "== deterministic replay of trace1 (proves reproducibility) =="
rout="$(rr replay -a "$trace_dir/trace1" 2>&1)"; rrc=$?
echo "$rout" | grep -E "OK|soak|Assert|Error" || true
if [ "$rrc" -ne 0 ]; then
  echo "FAIL: rr replay exited $rrc" >&2; exit 1
fi

echo "[OK] rr chaos: $iters chaos-scheduled recordings + 1 replay, oracle held each run"
