## Compiles the set WITH the deterministic schedule hooks enabled
## (`-d:shmGSetScheduleHooks`) and proves (a) the seams fire at the documented
## points and (b) installing a hook does not change the observable result — the
## scaffolding M2's adversarial-interleaving tests build on (M1 exit criteria).

import std/[os, sets, strutils, tables, unittest]
import shm_gset

static: doAssert scheduleHooksEnabled, "expected -d:shmGSetScheduleHooks"

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-hk-" & tag & "-" & $getCurrentProcessId() & "-" & $tmpCtr)
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

# --- the filesystem cost of a reader walk over retired shards -------------
#
# Regression cases for reprobuild-pm issue
# `2026-11-19-a-walk-probes-every-retired-shard-so-zero-syscall-lookups-are-overstated.md`.
#
# A flattener retires a shard by unlinking its file; the index stays below the
# chain count for the life of the chain. A handle that never mapped that shard
# (every engine that attached after the flatten) used to `stat` it on EVERY
# walk, so a negative lookup the per-edge store specifies as "zero filesystem
# operations" cost one syscall per retired shard, growing with every flatten.
#
# The syscalls are counted through the `spShardFileProbe` seam rather than
# strace: it fires immediately before each filesystem call `openShard` makes,
# which is every filesystem call `contains` and `withPrimaryKeyHash` can make
# (`items` and `claimedSlots` also scan the directory, which this seam does
# not count). No mock is involved;
# the chain, the files and the unlinks are real.

var probeCount {.threadvar.}: int

proc countProbes(p: SchedulePoint) {.gcsafe, raises: [].} =
  if p == spShardFileProbe: inc probeCount

proc shardFile(path0: string; k: int): string =
  path0[0 ..< path0.len - ".shard0".len] & ".shard" & $k

proc fillToInsertShard(s: var ShmGSet; target: int; tag: string): seq[string] =
  ## Insert distinct elements until inserts target shard `target`; returns
  ## every element inserted, so the caller can check none was lost.
  var i = 0
  while s.insertShardIndex() < target:
    let e = tag & "-" & $i
    doAssert s.insert(bytesOf(e)) in {isInserted, isExists}
    result.add e
    inc i

proc flattenAndRetire(s: var ShmGSet; k: int) =
  ## What a flattener does to shard `k`: copy its live elements forward, then
  ## publish the drained flag, then unlink the file.
  var copied: seq[seq[byte]]
  for v in s.shardElements(k): copied.add v.toBytesSeq()
  for e in copied: doAssert s.insert(e) in {isInserted, isExists}
  doAssert s.markShardDrained(k)
  doAssert s.retireShard(k)

proc warmWalks(s: var ShmGSet) =
  ## One pass of each reader walk, so every live shard is mapped and every
  ## index the handle can learn about has been probed once.
  discard s.contains(bytesOf("warm-absent"))
  for v in s.withPrimaryKey(bytesOf("warm-absent")): discard
  for e in s.items: discard

suite "reader walks over retired shards (filesystem cost)":
  test "a handle that attached after a flatten probes no retired shard twice":
    let dir = freshDir("retired-cost")
    defer: removeDir(dir)
    var owner = createSet(dir, "io-mon", "run", shard0Cap = 16,
      shard0ArenaCap = 1024)
    check owner.available
    let inserted = owner.fillToInsertShard(3, "elem")
    owner.flattenAndRetire(1)
    owner.flattenAndRetire(2)
    check (not fileExists(shardFile(owner.path0, 1)))
    check (not fileExists(shardFile(owner.path0, 2)))

    # A fresh handle maps shards lazily, per handle: it has never mapped the
    # retired shards, which is exactly the engine that attached after the
    # flatten.
    var fresh = attachSet(owner.path0)
    check fresh.available
    probeCount = 0
    setScheduleHook(countProbes)
    fresh.warmWalks()
    # The warm-up is allowed to learn: each retired index costs its probe once.
    check probeCount > 0

    probeCount = 0
    for i in 0 ..< 100:
      check (not fresh.contains(bytesOf("absent-" & $i)))
    let containsProbes = probeCount
    probeCount = 0
    for i in 0 ..< 100:
      for v in fresh.withPrimaryKeyHash(uint64(i) * 0x9E3779B97F4A7C15'u64):
        discard
    let walkProbes = probeCount
    probeCount = 0
    check (not fresh.shardIsDrained(0))
    check fresh.shardIsDrained(1)              # retired reads as drained...
    check fresh.shardIsDrained(2)
    check fresh.claimedSlots() > 0
    let otherProbes = probeCount               # ...without a probe either
    setScheduleHook(nil)
    checkpoint "probes over 100 contains: " & $containsProbes &
      ", over 100 withPrimaryKeyHash walks: " & $walkProbes &
      ", over shardIsDrained/claimedSlots: " & $otherProbes
    check containsProbes == 0
    check walkProbes == 0
    check otherProbes == 0

    # Remembering the absence changed no answer.
    for e in inserted: check fresh.contains(bytesOf(e))
    var got = initHashSet[string]()
    for e in fresh.items: got.incl strOf(e)
    check got == toHashSet(inserted)
    check fresh.growthFailures() == 0
    check fresh.retireShard(1)                 # still idempotent
    fresh.detach(); owner.detach()

  test "a present shard that will not map is still probed and counted every walk":
    # The control: a failure that is NOT known absence must never be
    # remembered. The file is present, so its elements exist and a walk that
    # skips them must keep saying so in `growthFailures`, and must keep trying,
    # because the condition (a descriptor limit, permissions) can clear.
    let dir = freshDir("unmappable-cost")
    defer: removeDir(dir)
    var owner = createSet(dir, "io-mon", "run", shard0Cap = 16,
      shard0ArenaCap = 1024)
    check owner.available
    discard owner.fillToInsertShard(3, "elem")
    # Replace shard 1 with a file that fails the header check. Unlink first so
    # the owner's existing mapping keeps its own inode instead of being
    # truncated under it. Larger than a header, so the open fails on the
    # header, not on size.
    let p1 = shardFile(owner.path0, 1)
    removeFile(p1)
    writeFile(p1, repeat('X', 64 * 1024))

    var fresh = attachSet(owner.path0)
    check fresh.available
    setScheduleHook(countProbes)
    fresh.warmWalks()
    let failuresBefore = fresh.growthFailures()
    check failuresBefore > 0
    probeCount = 0
    for i in 0 ..< 10:
      discard fresh.contains(bytesOf("absent-" & $i))
    let probes = probeCount
    setScheduleHook(nil)
    checkpoint "probes over 10 contains with an unmappable shard: " & $probes
    check probes >= 10                         # retried on every walk
    check fresh.growthFailures() >= failuresBefore + 10   # counted every walk
    fresh.detach(); owner.detach()

  test "an absent file at or above the chain count is not remembered":
    # Absence proves retirement only below the chain count as read before the
    # probe: a grower links the next shard BEFORE it bumps the count, so an
    # index the count has not reached may simply not have been created yet.
    let dir = freshDir("future-cost")
    defer: removeDir(dir)
    var owner = createSet(dir, "io-mon", "run", shard0Cap = 16,
      shard0ArenaCap = 1024)
    check owner.available
    discard owner.fillToInsertShard(1, "elem")
    let n = owner.insertShardIndex() + 1       # the chain count
    check (not fileExists(shardFile(owner.path0, n)))

    var fresh = attachSet(owner.path0)
    check fresh.available
    fresh.warmWalks()
    setScheduleHook(countProbes)
    probeCount = 0
    check fresh.shardIsDrained(n)              # absent: reads as skippable
    check probeCount > 0                       # and it really did probe
    setScheduleHook(nil)

    # Now the chain grows into index n and something lands there.
    let later = owner.fillToInsertShard(n, "later")
    let last = later[^1]
    check owner.insert(bytesOf("in-new-shard")) in {isInserted, isExists}
    check fileExists(shardFile(owner.path0, n))

    check (not fresh.shardIsDrained(n))        # seen, not remembered as gone
    check fresh.contains(bytesOf("in-new-shard"))
    check fresh.contains(bytesOf(last))
    var got = initHashSet[string]()
    for e in fresh.items: got.incl strOf(e)
    check "in-new-shard" in got
    check fresh.growthFailures() == 0
    fresh.detach(); owner.detach()
