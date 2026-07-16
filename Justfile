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
soak seconds="60":
    SHM_SET_SOAK_SECONDS={{seconds}} nim c -r {{nim_flags}} tests/test_shm_set_soak.nim

# Build + run the M1 transport head-to-head benchmark (needs nim-shm-queue).
bench:
    nim c -r {{nim_flags}} -d:release --path:../nim-shm-queue/src \
        benchmarks/bench_transports.nim
