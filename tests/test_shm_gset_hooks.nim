## Compiles the set WITH the deterministic schedule hooks enabled
## (`-d:shmSetScheduleHooks`) and proves (a) the seams fire at the documented
## points and (b) installing a hook does not change the observable result — the
## scaffolding M2's adversarial-interleaving tests build on (M1 exit criteria).

import std/[os, posix, sets, tables, unittest]
import shm_gset

static: doAssert scheduleHooksEnabled, "expected -d:shmSetScheduleHooks"

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-hk-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result); createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

var hitCounts {.threadvar.}: Table[SchedulePoint, int]

suite "schedule hooks":
  test "hooks fire at CAS/publish/shard-link sites and preserve results":
    let dir = freshDir("hooks")
    defer: removeDir(dir)
    hitCounts = initTable[SchedulePoint, int]()
    setScheduleHook(proc (p: SchedulePoint) {.gcsafe, raises: [].} =
      {.gcsafe.}:
        hitCounts.mgetOrPut(p, 0).inc)

    # tiny geometry so we exercise slot-claim, arena publish AND a shard link
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 32, shard0ArenaCap = 1024)
    check s.available
    var expected = initHashSet[string]()
    for i in 0 ..< 500:
      let e = "dep-" & $i
      expected.incl e
      check s.insert(bytesOf(e)) in {isInserted, isExists}

    # The publish seams for a fresh insert must have fired.
    check hitCounts.getOrDefault(spBeforeSlotCas, 0) > 0
    check hitCounts.getOrDefault(spAfterSlotCas, 0) > 0
    check hitCounts.getOrDefault(spBeforeArenaPublish, 0) > 0
    check hitCounts.getOrDefault(spBeforeArenaReserve, 0) > 0
    # Growth must have happened (tiny shard0), so the shard-link seams fired.
    check s.shardCount() > 1
    check hitCounts.getOrDefault(spBeforeShardLink, 0) > 0
    check hitCounts.getOrDefault(spAfterShardLink, 0) > 0
    check hitCounts.getOrDefault(spBeforeChainBump, 0) > 0

    # Result is unchanged by the presence of the hook.
    var got = initHashSet[string]()
    for e in s.items:
      got.incl(strOf(e))
    check got == expected
    setScheduleHook(nil)
    s.detach()
