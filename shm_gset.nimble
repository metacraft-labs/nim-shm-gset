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
  # The same suite compiled with the deterministic schedule hooks enabled, to
  # prove the test-only seams compile and stay behaviour-preserving.
  exec "nim c -r --hints:off --threads:on --warning:BareExcept:off " &
    "-d:shmSetScheduleHooks tests/test_shm_gset_hooks.nim"
