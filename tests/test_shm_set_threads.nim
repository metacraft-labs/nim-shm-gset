## Single-process THREAD harness for `nim-shm-set` (design spec §4.5(g)).
##
## Many threads insert DISJOINT distinct sets concurrently into the same shard
## chain (each thread its own mmap view; the shared state is the file-backed
## segment, touched only through the C11 atomics). The single-threaded reader
## then asserts the exact union — zero loss, zero phantom, growthFailures == 0.
##
## Built plainly for a fast functional check, and — crucially — this is the exact
## binary run under TSAN (`--passc/--passl:-fsanitize=thread -d:useMalloc`) and
## ASan/UBSan to validate the algorithm's memory ordering. TSAN validates only the
## THREAD-level algorithm; it does NOT cross the process boundary, so the
## multi-process layer is checked separately by the fork tests. It also stresses
## the same-process concurrent-grow path (heavy sharding), i.e. the temp-name
## uniqueness fix.

import std/[os, posix, sets, strutils]
import shm_set

# Geometry defaults match the historical fast functional/TSAN run. They can be
# scaled DOWN via env for the much slower happens-before detectors (valgrind
# DRD/helgrind, `just test-valgrind`), which run the SAME binary/atomics but at
# a ~30-50x slowdown, so a smaller distinct set keeps the run bounded while
# still exercising concurrent slot-claim + grow.
let
  nThreads = block:
    try: max(1, parseInt(getEnv("SHM_SET_THREADS", "6"))) except ValueError: 6
  perThread = block:
    try: max(1, parseInt(getEnv("SHM_SET_PER_THREAD", "800"))) except ValueError: 800

var gPath0: string

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc inserter(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var s = attachSet(gPath0)
    doAssert s.available
    for j in 0 ..< perThread:
      let e = "t" & $id & "/e" & $j
      var b = newSeq[byte](e.len)
      for k, c in e: b[k] = byte(c)
      doAssert s.insert(b) in {isInserted, isExists}
    s.detach()

when isMainModule:
  let dir = getTempDir() / ("shmset-threads-" & $getpid())
  removeDir(dir); createDir(dir)
  # Small geometry so the many threads force real concurrent sharding.
  var host = createSet(dir, "io-mon", "edge", shard0Cap = 128, shard0ArenaCap = 8192)
  doAssert host.available
  gPath0 = host.path0

  var ts = newSeq[Thread[int]](nThreads)
  for i in 0 ..< nThreads: createThread(ts[i], inserter, i)
  for i in 0 ..< nThreads: joinThread(ts[i])

  var expected = initHashSet[string]()
  for i in 0 ..< nThreads:
    for j in 0 ..< perThread: expected.incl("t" & $i & "/e" & $j)
  var got = initHashSet[string]()
  for e in host.items: got.incl strOf(e)
  doAssert got.len == expected.len,
    "loss/phantom: got " & $got.len & " want " & $expected.len
  doAssert got == expected
  doAssert host.growthFailures() == 0
  host.assertNoAbsolutePointers()
  let sc = host.shardCount()
  host.detach()
  removeDir(dir)
  echo "[OK] thread harness: ", nThreads, " threads x ", perThread,
    " distinct == exact union; growthFailures=0; shards=", sc
