import std/[strutils]
version       = readFile("version.txt").strip()
author        = "Metacraft Labs"
description   = "Shared-memory, lock-free, file-backed grow-only SET (G-Set): " &
  "idempotent dedup-at-source over opaque byte blobs, grown by sharding."
license       = "Apache-2.0"
srcDir        = "src"
skipDirs      = @["tests", "benchmarks"]

requires "nim >= 2.0.0"

# The compile flags EVERY test binary is built with, in both runners. This must
# stay byte-identical to `nim_flags` in the Justfile, and it is not left to
# discipline: `scripts/check-runner-parity.sh` re-derives both sides from the
# two files and fails the build if the FILE SET or any file's FLAG SET differs.
# It runs as the first step of this task and of the Justfile `test` recipe.
#
# The two runners used to disagree here in a way nobody could see: the Justfile
# applied `--path:tests` to every compile while this task applied it to four
# files only. That divergence is removed rather than preserved — one flag
# string, applied uniformly, plus per-file `-d:` switches where a file needs a
# compile-time seam.
const testFlags = "--hints:off --threads:on --warning:BareExcept:off --path:src --path:tests"

task test, "Build + run the nim-shm-gset test suite":
  # PARITY GATE FIRST. `just test` and `nimble test` are two runners over one
  # suite, and for months four files (transport, lf5, concurrency, threads — 16
  # cases, including the §4.5 SIGKILL fault-injection battery) were reachable
  # from the Justfile ONLY. This task's own comments stated the rule that
  # forbids it; nothing checked it. Now something does.
  exec "bash scripts/check-runner-parity.sh"

  # Functional + concurrency (multi-process fork) suite for the sharded G-Set.
  exec "nim c -r " & testFlags & " tests/test_shm_gset.nim"
  # Transport layer: the LF-1 gate (a multi-process probe storm through `emit`
  # unions EXACTLY) and the LF-2 fail-fast gates (`emUnavailable` when the set
  # cannot be attached, `emOversize` past the cap). These are REQUIRED
  # lossless-capture gates and were reachable from the Justfile only.
  exec "nim c -r " & testFlags & " tests/test_shm_gset_transport.nim"
  # LF-5 (oversize is not loss): an element larger than a shard's arena is
  # captured by GROWTH, and a genuinely impossible allocation surfaces as
  # SIGNALLED saturation rather than a silent drop. Also Justfile-only until now.
  exec "nim c -r " & testFlags & " tests/test_shm_gset_lf5.nim"
  # Reaper identity: the runId lives in the shard HEADER, not the file name —
  # header attribution, appId scoping, both staleness axes, and migration of a
  # chain written under the pre-HM-1 naming + header layout.
  exec "nim c -r " & testFlags & " tests/test_shm_gset_reaper_identity.nim"
  # Reset / recycling (HM-2): generation-stamped O(1) recycling, the quiescence
  # refusal (including a detached descendant that outlived its root), the
  # consumer-liveness re-arm, and SIGKILL at every one of reset's publish
  # points. `-d:shmGSetScheduleHooks` is REQUIRED, not decorative — the file
  # does not compile without the kill-injection seams and the generation seam,
  # so this cannot silently degrade into a weaker run.
  exec "nim c -r " & testFlags & " -d:shmGSetScheduleHooks tests/test_shm_gset_reset.nim"
  # Version-skew diagnostic (HM-2). The rev-2 PEER is a SEPARATE binary on
  # purpose: a version skew is a disagreement between two builds and cannot be
  # exercised from inside one. Build it first; the test fails loudly (never
  # skips) if it is missing.
  exec "nim c " & testFlags & " -o:tests/helpers/v2_producer tests/helpers/v2_producer.nim"
  exec "nim c -r " & testFlags & " tests/test_shm_gset_version_skew.nim"
  # The same suite compiled with the deterministic schedule hooks enabled, to
  # prove the test-only seams compile and stay behaviour-preserving.
  exec "nim c -r " & testFlags & " -d:shmGSetScheduleHooks tests/test_shm_gset_hooks.nim"
  # The §4.5 multi-process fault-injection battery: SIGKILL at
  # `spBeforeSlotCas` / `spBeforeArenaPublish` / `spBeforeShardLink` /
  # `spBeforeChainBump`, two producers linking a shard concurrently with no
  # leaked file, position-independence at a deliberately different mmap base,
  # the arena release-publish visibility case, and the reaper `flock` race.
  # `-d:shmGSetScheduleHooks` is REQUIRED — the kill seams do not exist without
  # it and the file will not compile, so it cannot degrade into a weaker run.
  # These nine cases were reachable from the Justfile only.
  exec "nim c -r " & testFlags & " -d:shmGSetScheduleHooks tests/test_shm_gset_concurrency.nim"
  # The single-process thread harness — also the compilation unit
  # `test-sanitizers` and `test-valgrind` build under TSAN / ASan / helgrind /
  # DRD, so it must be exercised by both runners, not one.
  exec "nim c -r " & testFlags & " tests/test_shm_gset_threads.nim"
  # Host-side recycling POOL (HM-3): growth stops after warmup (measured against
  # an unpooled baseline in the same run), the structural guarantee that no
  # caller can acquire a chain that was not reset, N in-flight actions that
  # never share a chain, the consumer-identity rule for a pooled chain, and the
  # retry/retire policy for each `ResetStatus` refusal. Plus the three
  # properties the milestone asserted in prose before it tested them:
  # `release` marking the consumer gone for a late producer, what `close`
  # does and does NOT clean up when a lease was dropped, and that
  # `destroySetPool` frees the pool's own seq buffers (the valgrind gate for
  # the same leak lives in the Justfile's `test-valgrind`, since valgrind is
  # not assumed present here).
  # `-d:shmGSetScheduleHooks` is REQUIRED, not decorative — the
  # `rsGenerationExhausted` policy case needs the compile-time-gated generation
  # seam, so the file does not compile without it and cannot silently degrade.
  exec "nim c -r " & testFlags & " -d:shmGSetScheduleHooks tests/test_shm_gset_pool.nim"
  # The many-process soak oracle, which now also carries HM-3's `recycle_soak`:
  # N successive recycles through the pool with disjoint input sets, oracle =
  # each generation's union is EXACTLY its intended set.
  exec "nim c -r " & testFlags & " tests/test_shm_gset_soak.nim"
  # Algorithmic properties of the parameterised key discipline (probe-run
  # completeness, tombstone ordering, flatten/retire) plus its concurrency
  # oracles. `-d:nimAllocStats` instruments the allocator's alloc/dealloc
  # counters, which is what suite E measures; without it the runtime returns a
  # zeroed AllocStats and the measurement would be vacuous. E1 self-checks that
  # the counters are live and fails rather than passing emptily.
  exec "nim c -r " & testFlags & " -d:nimAllocStats tests/test_shm_gset_keyed.nim"
  exec "nim c -r " & testFlags & " tests/test_shm_gset_keyed_concurrency.nim"
