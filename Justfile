# nim-shm-set test + benchmark runner.
#
# `nimble test` also works, but only once the repo has at least one commit
# (nimble derives the package version from the VCS revision). This `just`
# runner needs no commit, so it is the blessed runner during development.

nim_flags := "--hints:off --threads:on --warning:BareExcept:off --path:src"

# Build + run the full functional + concurrency-verification suite (design spec
# §4.5). x86-64 Linux. Deterministic — no flaky stress in `test`.
test:
    nim c -r {{nim_flags}} tests/test_shm_set.nim
    nim c -r {{nim_flags}} tests/test_shm_set_transport.nim
    nim c -r {{nim_flags}} tests/test_shm_set_lf5.nim
    nim c -r {{nim_flags}} -d:shmSetScheduleHooks tests/test_shm_set_hooks.nim
    nim c -r {{nim_flags}} -d:shmSetScheduleHooks tests/test_shm_set_concurrency.nim
    nim c -r {{nim_flags}} tests/test_shm_set_threads.nim
    nim c -r {{nim_flags}} tests/test_shm_set_soak.nim

# Sanitizers (design spec §4.5(g)) — TSAN + ASan/UBSan over the single-process
# thread harness (the algorithm's memory ordering; TSAN does NOT cross the
# process boundary). `-d:useMalloc` routes Nim allocations through malloc so the
# sanitizers can track them. `detect_leaks=0`: Nim's runtime intentionally leaves
# reachable allocations at exit — the active checks are races (TSAN) and
# buffer/mmap bounds + UB (ASan/UBSan).
test-sanitizers:
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        --passc:-fsanitize=thread --passl:-fsanitize=thread \
        -o:/tmp/shmset-tsan-threads tests/test_shm_set_threads.nim
    TSAN_OPTIONS="halt_on_error=1" /tmp/shmset-tsan-threads
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        --passc:"-fsanitize=address,undefined -fno-sanitize-recover=undefined" \
        --passl:"-fsanitize=address,undefined" \
        -o:/tmp/shmset-asan-threads tests/test_shm_set_threads.nim
    ASAN_OPTIONS="detect_leaks=0" /tmp/shmset-asan-threads

# Longer parameterizable many-process soak (design spec §4.5(f)). The default in
# `test` is a short 2s; use this for a longer bounded run, e.g. `just soak 300`.
# The multi-HOUR version (hours, on x86 AND ARM64) is a CI concern; this target is
# the same harness, just run longer.
soak seconds="60":
    SHM_SET_SOAK_SECONDS={{seconds}} nim c -r {{nim_flags}} tests/test_shm_set_soak.nim

# Valgrind DRD + helgrind (design spec §4.5(g)) — a SECOND, happens-before race
# detector alongside TSAN, over the single-process thread harness (the SAME
# atomics that ship). Scaled down via env because the tools add a ~30-50x
# slowdown. NOTE ON COVERAGE: like TSAN, DRD/helgrind track shadow state by
# VIRTUAL ADDRESS, and each thread/process `mmap`s the file-backed segment at its
# OWN base (the real multi-process shape), so these tools cannot observe the
# cross-mapping shared-segment ordering — they validate thread lifecycle, the
# process-global temp-name atomic (`gShardTmpSeq`), and the allocator. The
# cross-mapping release->acquire ordering is proven by the formal/litmus
# artifacts (verification/) and exercised by the multi-process kill/oracle tests.
# Both tools run clean (0 errors), so no suppression file is needed.
test-valgrind:
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        -o:/tmp/shmset-vg-threads tests/test_shm_set_threads.nim
    SHM_SET_THREADS=3 SHM_SET_PER_THREAD=200 \
        valgrind --tool=helgrind --error-exitcode=99 /tmp/shmset-vg-threads
    SHM_SET_THREADS=3 SHM_SET_PER_THREAD=200 \
        valgrind --tool=drd --error-exitcode=99 /tmp/shmset-vg-threads

# TLA+/TLC model check of the protocol (design spec §4.5(a)). TLC is not in the
# dev shell, so this target pulls it from nixpkgs on demand. The PlusCal
# algorithm is already translated (the BEGIN/END TRANSLATION block in
# shm_set.tla); after editing the PlusCal, re-translate with `pcal shm_set.tla`.
# Proves LOGICAL protocol safety under interleavings; weak-memory sufficiency is
# the litmus/GenMC job (verification/litmus, verification/core).
verify-tla:
    cd verification/tla && nix shell nixpkgs#tlaplus --command \
        tlc -config shm_set_MC.cfg shm_set_MC.tla

# rr chaos-mode record + deterministic replay of the multi-process fork oracle
# (design spec §4.5(f)). Explores rare fork/grow interleavings under a randomised
# scheduler; every recording asserts `snapshot == union(intended)`. rr needs a HW
# CPU-cycle counter; on Intel hybrid parts pass RR_BIND_CPU to pin a P-core (the
# script defaults to cpu0). Tune with RR_CHAOS_ITERS / SHM_SET_SOAK_SECONDS.
test-rr:
    bash verification/run-rr-chaos.sh

# Build + run the M1 transport head-to-head benchmark (needs nim-shm-queue).
bench:
    nim c -r {{nim_flags}} -d:release --path:../nim-shm-queue/src \
        benchmarks/bench_transports.nim
