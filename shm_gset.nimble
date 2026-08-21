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
