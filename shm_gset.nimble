import std/[strutils]
version       = readFile("version.txt").strip()
author        = "Metacraft Labs"
description   = "Shared-memory, lock-free, file-backed grow-only SET (G-Set): " &
  "idempotent dedup-at-source over opaque byte blobs, grown by sharding."
license       = "Apache-2.0"
srcDir        = "src"
skipDirs      = @["tests", "benchmarks"]

requires "nim >= 2.0.0"

task test, "Build + run the nim-shm-gset test suite":
  # Functional + concurrency (multi-process fork) suite for the sharded G-Set.
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "tests/test_shm_gset.nim"
  # Reaper identity: the runId lives in the shard HEADER, not the file name —
  # header attribution, appId scoping, both staleness axes, and migration of a
  # chain written under the pre-HM-1 naming + header layout.
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "tests/test_shm_gset_reaper_identity.nim"
  # Reset / recycling (HM-2): generation-stamped O(1) recycling, the quiescence
  # refusal (including a detached descendant that outlived its root), the
  # consumer-liveness re-arm, and SIGKILL at every one of reset's publish
  # points. `-d:shmGSetScheduleHooks` is REQUIRED, not decorative — the file
  # does not compile without the kill-injection seams and the generation seam,
  # so this cannot silently degrade into a weaker run. Must stay in step with
  # the Justfile `test` recipe.
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "-d:shmGSetScheduleHooks tests/test_shm_gset_reset.nim"
  # Version-skew diagnostic (HM-2). The rev-2 PEER is a SEPARATE binary on
  # purpose: a version skew is a disagreement between two builds and cannot be
  # exercised from inside one. Build it first; the test fails loudly (never
  # skips) if it is missing. `--path:tests` picks up the keyed reference policy
  # the `afKeyDisciplineSkew` case needs.
  exec "nim c --hints:off --threads:on --warning:BareExcept:off " &
    "-o:tests/helpers/v2_producer tests/helpers/v2_producer.nim"
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "--path:tests tests/test_shm_gset_version_skew.nim"
  # The same suite compiled with the deterministic schedule hooks enabled, to
  # prove the test-only seams compile and stay behaviour-preserving.
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "-d:shmGSetScheduleHooks tests/test_shm_gset_hooks.nim"
  # Algorithmic properties of the parameterised key discipline (probe-run
  # completeness, tombstone ordering, flatten/retire) plus its concurrency
  # oracles. `--path:tests` picks up the action-cache reference key policy.
  # `-d:nimAllocStats` instruments the allocator's alloc/dealloc counters, which
  # is what suite E measures; without it the runtime returns a zeroed AllocStats
  # and the measurement would be vacuous. E1 self-checks that the counters are
  # live and fails rather than passing emptily, so this flag must stay in step
  # with the same flag in the Justfile `test` recipe.
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "-d:nimAllocStats --path:tests tests/test_shm_gset_keyed.nim"
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "--path:tests tests/test_shm_gset_keyed_concurrency.nim"
