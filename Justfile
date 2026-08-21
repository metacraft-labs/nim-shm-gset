# nim-shm-gset test + benchmark runner.
#
# `nimble test` also works, but only once the repo has at least one commit
# (nimble derives the package version from the VCS revision). This `just`
# runner needs no commit, so it is the blessed runner during development.

nim_flags := "--hints:off --threads:on --warning:BareExcept:off --path:src --path:tests"

# Build + run the full functional + concurrency-verification suite (design spec
# §4.5). x86-64 Linux. Deterministic — no flaky stress in `test`.
test:
    nim c -r {{nim_flags}} tests/test_shm_gset.nim
    nim c -r {{nim_flags}} tests/test_shm_gset_transport.nim
    nim c -r {{nim_flags}} tests/test_shm_gset_lf5.nim
    # Reaper identity: runId lives in the shard HEADER, not the file name —
    # header attribution, appId scoping, both staleness axes, and migration of a
    # chain written under the pre-HM-1 naming + header layout.
    nim c -r {{nim_flags}} tests/test_shm_gset_reaper_identity.nim
    # Reset / recycling: generation-stamped O(1) recycling, the quiescence
    # refusal (including a detached descendant that outlived its root), the
    # liveness re-arm, and SIGKILL at every one of reset's publish points.
    # -d:shmGSetScheduleHooks is REQUIRED, not decorative: the kill-injection
    # cases need the seams and the generation-exhaustion case needs the
    # test-only counter seam. Without it the file does not compile, so it cannot
    # silently degrade into a weaker run.
    nim c -r {{nim_flags}} -d:shmGSetScheduleHooks tests/test_shm_gset_reset.nim
    # Version-skew diagnostic. The rev-2 PEER is a separate binary on purpose —
    # a version skew is a disagreement between two BUILDS, so it cannot be
    # exercised from inside one. Build it first; the test fails loudly (never
    # skips) if it is absent.
    nim c {{nim_flags}} -o:tests/helpers/v2_producer tests/helpers/v2_producer.nim
    nim c -r {{nim_flags}} tests/test_shm_gset_version_skew.nim
    nim c -r {{nim_flags}} -d:shmGSetScheduleHooks tests/test_shm_gset_hooks.nim
    nim c -r {{nim_flags}} -d:shmGSetScheduleHooks tests/test_shm_gset_concurrency.nim
    nim c -r {{nim_flags}} tests/test_shm_gset_threads.nim
    nim c -r {{nim_flags}} tests/test_shm_gset_soak.nim
    # -d:nimAllocStats instruments the allocator's alloc/dealloc counters, which
    # is what suite E measures. WITHOUT it the runtime returns a zeroed
    # AllocStats unconditionally and E1 would pass vacuously; E1 self-checks
    # this and fails rather than passing emptily if the flag is dropped.
    nim c -r {{nim_flags}} -d:nimAllocStats tests/test_shm_gset_keyed.nim
    nim c -r {{nim_flags}} tests/test_shm_gset_keyed_concurrency.nim

# Sanitizers (design spec §4.5(g)) — TSAN + ASan/UBSan over the single-process
# thread harness (the algorithm's memory ordering; TSAN does NOT cross the
# process boundary). `-d:useMalloc` routes Nim allocations through malloc so the
# sanitizers can track them. `detect_leaks=0`: Nim's runtime intentionally leaves
# reachable allocations at exit — the active checks are races (TSAN) and
# buffer/mmap bounds + UB (ASan/UBSan).
test-sanitizers:
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        --passc:-fsanitize=thread --passl:-fsanitize=thread \
        -o:/tmp/shmgset-tsan-threads tests/test_shm_gset_threads.nim
    TSAN_OPTIONS="halt_on_error=1" /tmp/shmgset-tsan-threads
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        --passc:"-fsanitize=address,undefined -fno-sanitize-recover=undefined" \
        --passl:"-fsanitize=address,undefined" \
        -o:/tmp/shmgset-asan-threads tests/test_shm_gset_threads.nim
    ASAN_OPTIONS="detect_leaks=0" /tmp/shmgset-asan-threads
    # The same treatment for the KEYED discipline's concurrency suite, which
    # exercises the probe-run walk and the flatten/retire path under threads.
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        --passc:-fsanitize=thread --passl:-fsanitize=thread \
        -o:/tmp/shmgset-tsan-keyed tests/test_shm_gset_keyed_concurrency.nim
    TSAN_OPTIONS="halt_on_error=1" /tmp/shmgset-tsan-keyed

# Longer parameterizable many-process soak (design spec §4.5(f)). The default in
# `test` is a short 2s; use this for a longer bounded run, e.g. `just soak 300`.
# The multi-HOUR version (hours, on x86 AND ARM64) is a CI concern; this target is
# the same harness, just run longer.
soak seconds="60":
    SHM_GSET_SOAK_SECONDS={{seconds}} nim c -r {{nim_flags}} tests/test_shm_gset_soak.nim

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
        -o:/tmp/shmgset-vg-threads tests/test_shm_gset_threads.nim
    SHM_GSET_THREADS=3 SHM_GSET_PER_THREAD=200 \
        valgrind --tool=helgrind --error-exitcode=99 /tmp/shmgset-vg-threads
    SHM_GSET_THREADS=3 SHM_GSET_PER_THREAD=200 \
        valgrind --tool=drd --error-exitcode=99 /tmp/shmgset-vg-threads

# TLA+/TLC model check of the protocol (design spec §4.5(a)). TLC is not in the
# dev shell, so this target pulls it from nixpkgs on demand. The PlusCal
# algorithm is already translated (the BEGIN/END TRANSLATION block in
# shm_gset.tla); after editing the PlusCal, re-translate with `pcal shm_gset.tla`.
# Proves LOGICAL protocol safety under interleavings; weak-memory sufficiency is
# the litmus/GenMC job (verification/litmus, verification/core).
verify-tla:
    cd verification/tla && nix shell nixpkgs#tlaplus --command \
        tlc -config shm_gset_MC.cfg shm_gset_MC.tla
    # The KEYED discipline: primary hash over a sub-range of the element, so a
    # whole set of elements shares one probe run; plus tombstone eviction under a
    # global generation counter. Two racing producers over two primary keys that
    # SHARE a home slot.
    cd verification/tla && nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_gset_keyed_MC.cfg shm_gset_keyed_MC.tla
    # Flatten (copy forward -> drain -> retire) racing a concurrent reader.
    cd verification/tla && nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_gset_keyed_flat_MC.cfg shm_gset_keyed_flat_MC.tla
    # RESET / RECYCLING (HM-2): generation-stamped slots, the quiescence refusal
    # and its seal, and the liveness re-arm ordered before the commit. Checks
    # no cross-generation leakage, no loss after a reset, and that the liveness
    # token is never gone under a generation that is accepting inserts.
    cd verification/tla && nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_gset_reset_MC.cfg shm_gset_reset_MC.tla

# The C11 atomics cores (design spec §4.5(a)) as a native functional smoke, plus
# the RELAXED_SEAL control. The control is expected to REPORT straddles and
# cross-generation leaks — that is what shows the shipped seq_cst seal/registry
# handshake is load-bearing rather than decorative — so it never fails the
# build; only the SHIPPED build's oracles are hard assertions.
verify-core:
    cc -std=c11 -O2 -pthread -DSTANDALONE \
        -o /tmp/shm_gset_core_run verification/core/shm_gset_core.c
    /tmp/shm_gset_core_run
    cc -std=c11 -O2 -pthread -DSTANDALONE -DNITER=100000 \
        -o /tmp/shm_gset_reset_core_run verification/core/shm_gset_reset_core.c
    /tmp/shm_gset_reset_core_run
    cc -std=c11 -O2 -pthread -DSTANDALONE -DNITER=100000 -DRELAXED_SEAL \
        -o /tmp/shm_gset_reset_core_relaxed verification/core/shm_gset_reset_core.c
    /tmp/shm_gset_reset_core_relaxed
    cc -std=c11 -O1 -g -pthread -fsanitize=thread -DSTANDALONE -DNITER=2000 \
        -o /tmp/shm_gset_reset_core_tsan verification/core/shm_gset_reset_core.c
    TSAN_OPTIONS="halt_on_error=1" /tmp/shm_gset_reset_core_tsan

# Cross-build + run every C11 core for aarch64 under qemu-user (design spec §4.5
# ARM64 arm). FUNCTIONAL ONLY — qemu-user does not reproduce ARMv8 weak memory.
verify-aarch64:
    nix shell nixpkgs#pkgsCross.aarch64-multiplatform.buildPackages.gcc \
        nixpkgs#pkgsCross.aarch64-multiplatform.glibc \
        --command verification/core/build-aarch64-qemu.sh

# rr chaos-mode record + deterministic replay of the multi-process fork oracle
# (design spec §4.5(f)). Explores rare fork/grow interleavings under a randomised
# scheduler; every recording asserts `snapshot == union(intended)`. rr needs a HW
# CPU-cycle counter; on Intel hybrid parts pass RR_BIND_CPU to pin a P-core (the
# script defaults to cpu0). Tune with RR_CHAOS_ITERS / SHM_GSET_SOAK_SECONDS.
test-rr:
    bash verification/run-rr-chaos.sh

# Build + run the M1 transport head-to-head benchmark (needs nim-shm-queue).
bench:
    nim c -r {{nim_flags}} -d:release --path:../nim-shm-queue/src \
        benchmarks/bench_transports.nim
