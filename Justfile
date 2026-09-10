# nim-shm-gset test + benchmark runner.
#
# `nimble test` also works, but only once the repo has at least one commit
# (nimble derives the package version from the VCS revision). This `just`
# runner needs no commit, so it is the blessed runner during development.
# The two runners are now held to the SAME suite by `just check-runner-parity`,
# which both of them run first — see the note above that recipe. `nimble` itself
# is in this repo's flake (it is NOT in the workspace shell), so
# `nix develop . -c nimble test` is how the second runner is exercised.
#
# `nim_flags` below is one half of the parity contract: the nimble task's
# `const testFlags` must be byte-identical to it, and the gate checks that by
# expanding both and comparing per-file flag sets.
nim_flags := "--hints:off --threads:on --warning:BareExcept:off --path:src --path:tests"

# Every VERIFICATION tool (tlc, herd7, genmc, nidhugg, cdschecker, gcc, the
# aarch64 cross toolchain, qemu) comes from THIS repo's flake, which pins nixpkgs
# to one revision and packages the four checkers nixpkgs does not carry. It replaces
# the old `nix shell nixpkgs#...` calls, which resolved through the machine's
# mutable flake REGISTRY — i.e. against whatever nixpkgs that machine last
# synced. A repo whose product is verification evidence cannot have its evidence
# depend on that. See flake.nix and verification/README.md.
#
# `test`, `soak`, `bench`, `test-sanitizers` and `test-rr` deliberately still
# BUILD AND RUN entirely on the AMBIENT toolchain (the workspace dev shell),
# because that is what a developer edits and rebuilds against all day, and
# because this repo is consumed by io-mon as a plain source path (SHM_GSET_SRC)
# compiled by io-mon's OWN nim. The flake's shell carries the same Nim version
# (2.2.4) from the pinned nixpkgs, so `nix develop . -c just test` also works
# and gives the same 102 [OK] / 0 [FAILED] / 0 [SKIPPED]; it is simply not
# forced. (Re-measured 2026-08-22. This number was stale at 97 for two rounds;
# if you change the suite, re-measure it here and in verification/README.md
# rather than carrying the old one forward.)
#
# `test-valgrind` IS THE ONE EXCEPTION, and it used to be documented wrongly.
# The comment here and in verification/README.md both said it ran on the ambient
# toolchain; it never could, because `valgrind` is not in the workspace shell —
# it is in THIS repo's flake (flake.nix, "§4.5(g) dynamic tier (previously
# ambient, now pinned too)"), and the doc was not moved when the package was.
# Measured on the ambient shell: `just test-valgrind` died with
# `sh: line 1: valgrind: command not found`, exit 127. Rather than leave a
# target documented as runnable where it was not, the recipe now takes the
# valgrind BINARY from the pinned flake via {{verify_shell}} while still
# building the binaries under test with the ambient nim — so `just
# test-valgrind` works from a bare workspace shell, and the thing being measured
# is still the build a developer actually produces.
#
# `test-rr` WAS THE SAME DEFECT, and this comment used to assert the opposite —
# that `rr` is "genuinely ambient (it is in the user profile)". A user profile is
# not the workspace toolchain. Measured: `command -v rr` is EMPTY in a bare
# `nix develop <workspace>`, and `just test-rr` from one failed with
# `verification/run-rr-chaos.sh: line 40: rr: command not found` /
# `FAIL: rr record iteration 1 exited 127`. rr was already IN this repo's flake;
# only the wiring was missing. `verification/run-rr-chaos.sh` now resolves the rr
# BINARY from the pinned flake (one resolution for both record and replay — a
# trace can only be replayed by the rr that recorded it) while still building the
# harness with the ambient nim, exactly as `test-valgrind` does.
verify_shell := "nix develop --quiet " + justfile_directory() + " --command"

# TWO RUNNERS, ONE SUITE — and until now nothing checked that they agreed.
# `just test` compiled 102 [OK] worth of tests and `nimble test` 85: four files
# (transport, lf5, concurrency, threads — 16 cases, including the whole §4.5
# SIGKILL fault-injection battery and the LF-1/LF-2 lossless-capture gates) were
# reachable from THIS file only, for months, while both this recipe and the
# nimble task carried comments stating the rule that forbids it. The divergence
# was DISCOVERED (once nimble was finally installed and could be run at all),
# not caught. This gate re-derives the compiled file set AND the per-file flag
# set from both runner definitions and fails on any difference — including a
# test file on disk that neither runner builds. It is the first step of `test`
# here and the first `exec` of the nimble task, so neither runner can be used
# while they disagree. See scripts/check-runner-parity.sh.
check-runner-parity:
    bash scripts/check-runner-parity.sh

# Build + run the full functional + concurrency-verification suite (design spec
# §4.5). x86-64 Linux. Deterministic — no flaky stress in `test`.
test: check-runner-parity
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
    # Host-side recycling POOL (HM-3): growth stops after warmup (measured
    # against an unpooled baseline in the same run), the structural guarantee
    # that no caller can acquire a chain that was not reset, N in-flight actions
    # that never share a chain, the consumer-identity rule for a pooled chain,
    # and the retry/retire policy for each `ResetStatus` refusal. Plus the three
    # properties the milestone asserted in prose before it tested them:
    # `release` marking the consumer gone for a late producer, what `close`
    # does and does NOT clean up when a lease was dropped, and that
    # `destroySetPool` frees the pool's own seq buffers (whose valgrind gate is
    # in `test-valgrind`).
    # -d:shmGSetScheduleHooks is REQUIRED, not decorative: the
    # `rsGenerationExhausted` policy case needs the compile-time-gated
    # generation seam. Without it the file does not compile, so it cannot
    # silently degrade into a weaker run. Must stay in step with the nimble task.
    nim c -r {{nim_flags}} -d:shmGSetScheduleHooks tests/test_shm_gset_pool.nim
    # Soak: the §4.5(f) many-process oracle, plus (HM-3) `recycle_soak` — N
    # successive recycles through the pool with disjoint input sets, oracle =
    # each generation's union is EXACTLY its intended set.
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
    # The recycling POOL under N in-flight actions (HM-3). This one is NOT about
    # the segment's atomics — it is about the pool's own Nim-level state, and it
    # is here because it caught a real defect that every functional assertion
    # passed: a `ref` SetPool races its own ORC refcount across host threads
    # (ORC counters are atomic only under -d:gcAtomicArc), which TSAN reports as
    # races on `nimIncRef` / `nimDecRef` from `acquire` / `release` in two
    # different worker threads, and which manifests in the wild as a SIGSEGV
    # inside the runtime, far from the code responsible. The gate is NONZERO vs
    # ZERO, not a count: TSAN reports per observed schedule, so the number of
    # races on a `ref` build varies run to run and is not a specification. The
    # shipped `ptr` SetPool + lock-guarded GC'd fields is clean. Only the
    # concurrency case is run: the rest of that file forks, and TSAN and fork do
    # not mix.
    nim c {{nim_flags}} -d:shmGSetScheduleHooks --mm:orc -d:useMalloc --debugger:native \
        --passc:-fsanitize=thread --passl:-fsanitize=thread \
        -o:/tmp/shmgset-tsan-pool tests/test_shm_gset_pool.nim
    TSAN_OPTIONS="halt_on_error=1" /tmp/shmgset-tsan-pool \
        pool_under_concurrency_never_shares_a_chain

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
#
# The BINARIES are built with the ambient nim (the build a developer actually
# produces); only the `valgrind` executable comes from the pinned flake, because
# it is not in the workspace shell at all — see the note at the top of this file
# for the measurement that established that.
test-valgrind:
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        -o:/tmp/shmgset-vg-threads tests/test_shm_gset_threads.nim
    {{verify_shell}} env SHM_GSET_THREADS=3 SHM_GSET_PER_THREAD=200 \
        valgrind --tool=helgrind --error-exitcode=99 /tmp/shmgset-vg-threads
    {{verify_shell}} env SHM_GSET_THREADS=3 SHM_GSET_PER_THREAD=200 \
        valgrind --tool=drd --error-exitcode=99 /tmp/shmgset-vg-threads
    # MEMCHECK over a complete pool lifecycle (HM-3) — NOT a race check. The
    # pool object is `allocShared0` memory, which carries no destructor, so a
    # GC'd field of it that is merely TRUNCATED before `deallocShared`
    # (`seq.setLen(0)` keeps the payload buffer) is orphaned: a real
    # 136-bytes-per-pool leak, paid by every host that creates a pool per build
    # or per worker generation. `--errors-for-leak-kinds=definite` fails on
    # exactly that class and ignores the reachable-at-exit allocations Nim's
    # runtime intentionally leaves, which is why `detect_leaks=0` is right for
    # the sanitizer targets above and a leak gate is right here. The suite-side
    # guard for the same property is
    # `destroySetPool_frees_the_pools_own_buffers`.
    nim c {{nim_flags}} --mm:orc -d:useMalloc --debugger:native \
        -o:/tmp/shmgset-vg-pool tests/helpers/pool_lifecycle_probe.nim
    {{verify_shell}} valgrind --tool=memcheck --leak-check=full \
        --errors-for-leak-kinds=definite --error-exitcode=99 \
        /tmp/shmgset-vg-pool

# TLA+/TLC model check of the protocol (design spec §4.5(a)). TLC comes from the
# pinned flake (see `verify_shell` above). The PlusCal algorithm is already
# translated (the BEGIN/END TRANSLATION block in shm_gset.tla); after editing the
# PlusCal, re-translate with `pcal shm_gset.tla`.
# Proves LOGICAL protocol safety under interleavings; weak-memory sufficiency is
# the litmus/GenMC job (verification/litmus, verification/core).
verify-tla:
    cd verification/tla && {{verify_shell}} \
        tlc -config shm_gset_MC.cfg shm_gset_MC.tla
    # The KEYED discipline: primary hash over a sub-range of the element, so a
    # whole set of elements shares one probe run; plus tombstone eviction under a
    # global generation counter. Two racing producers over two primary keys that
    # SHARE a home slot.
    cd verification/tla && {{verify_shell}} \
        tlc -workers 4 -config shm_gset_keyed_MC.cfg shm_gset_keyed_MC.tla
    # Flatten (copy forward -> drain -> retire) racing a concurrent reader.
    cd verification/tla && {{verify_shell}} \
        tlc -workers 4 -config shm_gset_keyed_flat_MC.cfg shm_gset_keyed_flat_MC.tla
    # RESET / RECYCLING (HM-2): generation-stamped slots, the quiescence refusal
    # and its seal, and the liveness re-arm ordered before the commit. Checks
    # no cross-generation leakage, no loss after a reset, and that the liveness
    # token is never gone under a generation that is accepting inserts.
    cd verification/tla && {{verify_shell}} \
        tlc -workers 4 -config shm_gset_reset_MC.cfg shm_gset_reset_MC.tla
    # HOST-SIDE RECYCLING POOL (HM-3): the acquire / reset / lease / release /
    # retire lifecycle N in-flight actions drive around `reset`. The pool adds
    # no new SHARED-MEMORY protocol — its only segment operations are the ones
    # the reset model above and the C11 cores already cover — but it does add a
    # concurrent LIFECYCLE whose safety properties nothing else states: no two
    # actions share a chain, no chain is ever handed out whose generation did
    # not advance past the one the pool was holding (i.e. it was reset), a
    # leased chain is never recycled under its holder, retirement is final, no
    # chain is lost track of, and a permanently unrecyclable chain is retired
    # rather than kept warm forever.
    cd verification/tla && {{verify_shell}} \
        tlc -workers 4 -config shm_gset_pool_MC.cfg shm_gset_pool_MC.tla

# The C11 atomics cores (design spec §4.5(a)) as a native functional smoke, plus
# the RELAXED_SEAL control. The control is expected to REPORT straddles and
# cross-generation leaks — that is what shows the shipped seq_cst seal/registry
# handshake is load-bearing rather than decorative — so it never fails the
# build; only the SHIPPED build's oracles are hard assertions.
verify-core:
    {{verify_shell}} cc -std=c11 -O2 -pthread -DSTANDALONE \
        -o /tmp/shm_gset_core_run verification/core/shm_gset_core.c
    /tmp/shm_gset_core_run
    {{verify_shell}} cc -std=c11 -O2 -pthread -DSTANDALONE -DNITER=100000 \
        -o /tmp/shm_gset_reset_core_run verification/core/shm_gset_reset_core.c
    /tmp/shm_gset_reset_core_run
    {{verify_shell}} cc -std=c11 -O2 -pthread -DSTANDALONE -DNITER=100000 -DRELAXED_SEAL \
        -o /tmp/shm_gset_reset_core_relaxed verification/core/shm_gset_reset_core.c
    /tmp/shm_gset_reset_core_relaxed
    {{verify_shell}} cc -std=c11 -O1 -g -pthread -fsanitize=thread -DSTANDALONE -DNITER=2000 \
        -o /tmp/shm_gset_reset_core_tsan verification/core/shm_gset_reset_core.c
    TSAN_OPTIONS="halt_on_error=1" /tmp/shm_gset_reset_core_tsan

# herd7 litmus tests (design spec §4.5(a)), in two tiers: the `C` tests under the
# C11 LANGUAGE model, and hand-written AArch64 / RISC-V / x86-64 assembly
# translations under the per-architecture HARDWARE models. The runner checks
# every result against the expectation the test file declares and fails on a
# mismatch in EITHER direction — a shipped test that becomes Allowed, or a
# -RELAXED-control that becomes Forbidden (which would mean the control no
# longer shows the shipped ordering is load-bearing).
verify-litmus:
    {{verify_shell}} verification/litmus/run-litmus.sh

# Stateless model checking of the C11 cores under weak memory (design spec
# §4.5(a)) — the tier TLA+ cannot reach, because TLC explores sequentially
# consistent interleavings only.
#
# GenMC also closes the `m6` gap: the TLA+ reset model makes `PAttach` atomic, so
# it cannot express "a producer registered but missed the seal". GenMC runs the
# real C11 core, where attach is CAS-then-load-seal, so it can — and the
# RELAXED_SEAL control below is where it does, with a concrete counterexample
# trace rather than a probability.
#
# `-disable-ipr`: the cores use a hand-rolled spin barrier in which two threads
# store the same value to `bar_go`. GenMC's in-place-revisiting optimisation
# treats such unordered writes as an error; they are intentional here.
verify-models:
    # Insert core, shipped orders.
    {{verify_shell}} genmc -unroll=5 -- -std=c11 verification/core/shm_gset_core.c
    # Reset core, shipped orders: must be clean.
    {{verify_shell}} genmc -disable-ipr -unroll=5 -- -std=c11 \
        verification/core/shm_gset_reset_core.c
    # Reset core, RELAXED_SEAL control: GenMC MUST find the straddle. `!` because
    # a clean run here is the failure — it would mean the control is vacuous.
    ! {{verify_shell}} genmc -disable-ipr -unroll=5 -- -std=c11 -DRELAXED_SEAL \
        verification/core/shm_gset_reset_core.c
    # Second, independent checker over the same source — a single model checker
    # agreeing with itself is not corroboration.
    #
    # NOT `--arm`, and the reason is worth recording rather than quietly
    # omitting: Nidhugg IS built against LLVM 15 here specifically so that its
    # ARM model is selectable at all (it refuses for LLVM >= 16), but its ARM /
    # POWER trace builders reject read-modify-write instructions —
    #   Error: Unsupported instruction: %12 = atomicrmw add i32* %7, i32 1 seq_cst
    # — and the core's arena bump and slot CAS are both RMWs. The ARMv8 coverage
    # therefore comes from herd7 (verification/litmus/arch/*.AArch64.litmus) and
    # from GenMC's RC11 run above, not from this tool.
    {{verify_shell}} nidhuggc --c -- --sc  --unroll=5 verification/core/shm_gset_core.c
    {{verify_shell}} nidhuggc --c -- --tso --unroll=5 verification/core/shm_gset_core.c
    {{verify_shell}} nidhuggc --c -- --pso --unroll=5 verification/core/shm_gset_core.c

# CDSChecker (design spec §4.5(a)) — a THIRD independent C11 model checker over
# the same publish and handshake shapes. These are hand ports rather than the
# shipped cores, because CDSChecker replaces the atomics and thread APIs; see
# verification/cdschecker/seal-vs-register.c for why.
verify-cdschecker:
    {{verify_shell}} verification/cdschecker/run-cdschecker.sh

# Cross-build + run every C11 core for aarch64 under qemu-user (design spec §4.5
# ARM64 arm). FUNCTIONAL ONLY — qemu-user does not reproduce ARMv8 weak memory;
# the ARMv8 WEAK-MEMORY coverage is `verify-litmus` (arch/*.AArch64.litmus, under
# aarch64.cat) and `verify-models` (GenMC under RC11, which is sound for ARMv8
# via the proven compilation scheme).
verify-aarch64:
    nix shell {{justfile_directory()}}#aarch64-cross-env --command \
        verification/core/build-aarch64-qemu.sh

# The whole §4.5 formal / weak-memory tier, in dependency order.
verify: verify-tla verify-core verify-litmus verify-models verify-cdschecker verify-aarch64

# rr chaos-mode record + deterministic replay of the multi-process fork oracle
# (design spec §4.5(f)). Explores rare fork/grow interleavings under a randomised
# scheduler; every recording asserts `snapshot == union(intended)`. rr needs a HW
# CPU-cycle counter; on Intel hybrid parts pass RR_BIND_CPU to pin a P-core (the
# script defaults to cpu0). Tune with RR_CHAOS_ITERS / SHM_GSET_SOAK_SECONDS.
# The harness is built with the ambient nim; the rr BINARY comes from this repo's
# pinned flake (see the note at the top of this file, and SHM_GSET_RR to override).
test-rr:
    bash verification/run-rr-chaos.sh

# Build + run the M1 transport head-to-head benchmark (needs nim-shm-queue).
bench:
    nim c -r {{nim_flags}} -d:release --path:../nim-shm-queue/src \
        benchmarks/bench_transports.nim
