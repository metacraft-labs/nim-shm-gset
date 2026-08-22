## MEMCHECK fixture for `just test-valgrind` — a complete `SetPool` lifecycle,
## and nothing else, so that any block valgrind calls "definitely lost" belongs
## to the pool.
##
## WHY IT IS A SEPARATE BINARY. The property is about what is still allocated
## when the process EXITS, so it cannot be asserted from inside a suite that
## goes on to run other cases; and the suite's other cases `fork`, which turns a
## leak report into noise. This program creates pools, drives real acquires and
## releases over real shard files, destroys the pools, and returns.
##
## `SetPoolObj` lives in `allocShared0` memory, which carries no destructor: a
## GC'd field of it that is merely TRUNCATED (`seq.setLen(0)` keeps the payload
## buffer) is orphaned by `deallocShared`. That was a real 136-bytes-per-pool
## leak, paid by any host that creates a pool per build or per worker
## generation. Nothing is mocked here; `destroySetPool_frees_the_pools_own_
## buffers` in `tests/test_shm_gset_pool.nim` guards the same property from
## inside the suite, using shared-heap occupancy over many lifecycles.
##
## THE NUMBER TO EXPECT, if you revert the fix to check the gate still bites:
## this program runs TWO complete pool lifecycles, so memcheck reports one loss
## record per pool — `272 bytes in 2 blocks are definitely lost`, `ERROR
## SUMMARY: 2 errors from 2 contexts`, exit 99 (measured 2026-08-22). The
## `1 errors from 1 contexts` quoted in the original diagnosis came from a
## one-pool scratch program, not from this file. 136 bytes is the PER-POOL
## figure and is the one to quote.

import std/[os, strutils]
import shm_gset/transport
import shm_gset/pool

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc fill(path0, tag: string; n: int) =
  var pr = attachProducer(path0)
  doAssert pr.available
  for j in 0 ..< n:
    doAssert pr.emit(bytesOf(tag & "/path/to/file-" & $j & ".h")) in
      {emInserted, emExists}
  pr.detach()

proc shardFileCount(dir: string): int =
  for _, p in walkDir(dir):
    if ".shard" in extractFilename(p): inc result

proc main() =
  let dir = getTempDir() / ("shmgset-vg-pool-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  # (1) the ordinary lifecycle: several actions, all released, closed cleanly.
  block:
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
      maxIdle = 4)
    for r in 0 ..< 6:
      var l = p.acquire("vg-" & $r)
      doAssert l.available
      fill(l.path0, "r" & $r, 60)
      doAssert l.snapshot().len == 60
      l.release()
    doAssert p.idleChains > 0        # the idle seq really has a payload buffer
    doAssert p.close() == 0
    destroySetPool(p)
    doAssert p == nil

  # (2) a pool destroyed with a lease still outstanding, so the `created` sweep
  #     and the retire path are both exercised before `deallocShared`.
  block:
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
      maxIdle = 1)
    var a = p.acquire("vg-outstanding")
    doAssert a.available
    fill(a.path0, "out", 60)
    var b = p.acquire("vg-released")
    doAssert b.available
    b.release()
    doAssert p.close() == 1
    destroySetPool(p)
    doAssert p == nil

  doAssert shardFileCount(dir) == 0     # destroySetPool swept the dropped chain
  echo "pool_lifecycle_probe ok"

main()
