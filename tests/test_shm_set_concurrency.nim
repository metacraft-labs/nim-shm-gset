## Deterministic concurrency verification for `nim-shm-set` (design spec §4.5).
## Built with `-d:shmSetScheduleHooks --threads:on`. Every window below is driven
## to a SPECIFIC interleaving via the schedule hooks (barrier + release), so these
## are DETERMINISTIC regression tests, not flaky stress. x86-64 Linux.
##
## Coverage:
##   §4.5(b) position-independence via MAP_FIXED at a deliberately chosen base +
##           the absolute-pointer debug assertion.
##   §4.5(c) slot-claim race, double-grow (no leaked shard/.shardtmp), arena
##           reserve/publish ordering (torn read), reaper-vs-flock.
##   §4.5(d) real multi-process (fork) SIGKILL fault injection at every publish
##           point; the single-threaded reader's union stays correct.

import std/[os, posix, sets, strutils, tables, times, unittest, atomics]
import shm_set

static: doAssert scheduleHooksEnabled, "expected -d:shmSetScheduleHooks"

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)
proc flock(fd: cint; op: cint): cint {.importc, header: "<sys/file.h>".}
const LOCK_EX = cint(2)
const LOCK_UN = cint(8)

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmset-cc-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result); createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc countNameContains(dir, needle: string): int =
  for _, p in walkDir(dir):
    if needle in extractFilename(p): inc result

# --- thread coordination (barrier at a chosen schedule point) ---------------

var gArrived: Atomic[int]
var gRelease: Atomic[int]
var gHookPoint: SchedulePoint
var gPath0: string
var gThreadElems: array[2, seq[seq[byte]]]
var gFirstStatus: array[2, InsertStatus]
var tPaused {.threadvar.}: bool

proc pauseHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  ## Pause the FIRST time this thread hits the chosen point; signal arrival and
  ## spin until the driver releases. Deterministic window: once both threads have
  ## arrived, neither has yet executed the guarded CAS/link.
  if p == gHookPoint and not tPaused:
    tPaused = true
    discard gArrived.fetchAdd(1)
    while gRelease.load(moAcquire) == 0:
      discard sched_yield()

proc workerThread(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var s = attachSet(gPath0)
    doAssert s.available
    setScheduleHook(pauseHook)
    for i in 0 ..< gThreadElems[id].len:
      let st = s.insert(gThreadElems[id][i])
      if i == 0: gFirstStatus[id] = st
    setScheduleHook(nil)
    s.detach()

proc waitArrived(target: int; sec: float): bool =
  let dl = epochTime() + sec
  while gArrived.load(moAcquire) < target:
    if epochTime() > dl: return false
    discard sched_yield()
  true

proc resetBarrier() =
  gArrived.store(0)
  gRelease.store(0)

# --- (b) position-independence via MAP_FIXED --------------------------------

suite "position-independence via MAP_FIXED (design spec §4.5(b))":
  test "a shard mapped at a deliberately chosen base sees the identical set":
    let dir = freshDir("mapfixed")
    defer: removeDir(dir)
    var owner = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = 2048)
    check owner.available
    var expected = initHashSet[string]()
    for i in 0 ..< 1200:
      let e = "elem-" & $i
      expected.incl e
      discard owner.insert(bytesOf(e))
    check owner.shardCount() > 1

    # Reserve a region of exactly shard0's size at an address the kernel hands us,
    # then force the next attach to map shard0 THERE via MAP_FIXED — a base of our
    # choosing that differs from the owner's mapping. Offsets-only ⇒ identical
    # results; any leaked absolute pointer would fault or mismatch here.
    let sz = int(getFileSize(owner.path0))
    let want = mmap(nil, sz, PROT_NONE, MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    check want != MAP_FAILED
    setForcedNextMapBase(want)
    var view = attachSet(owner.path0)
    check view.available
    check cast[uint](view.shards0Base()) == cast[uint](want)
    check cast[uint](view.shards0Base()) != cast[uint](owner.shards0Base())

    for e in expected:
      check view.contains(bytesOf(e))
    var got = initHashSet[string]()
    for e in view.items: got.incl strOf(e)
    check got == expected

    # Debug: no stored slot value is an absolute pointer into the mapping.
    view.assertNoAbsolutePointers()
    owner.assertNoAbsolutePointers()
    view.detach(); owner.detach()

# --- (c) slot-claim race ----------------------------------------------------

proc collidingPair(cap: int): (seq[byte], seq[byte]) =
  ## Two DISTINCT elements whose home slot (fingerprint & mask) is identical, so
  ## two producers contend for the very same empty slot.
  let mask = uint64(cap - 1)
  var byHome = initTable[uint64, string]()
  var i = 0
  while true:
    let s = "collide-" & $i
    let fp = fingerprint(bytesOf(s)) or 1'u64
    let home = fp and mask
    if home in byHome:
      return (bytesOf(byHome[home]), bytesOf(s))
    byHome[home] = s
    inc i
    doAssert i < 1_000_000, "no colliding pair found"

suite "slot-claim race (design spec §4.5(c))":
  test "two producers CAS the same slot for distinct elements; both land":
    let dir = freshDir("slotrace")
    defer: removeDir(dir)
    const cap = 64
    var host = createSet(dir, "io-mon", "edge", shard0Cap = cap, shard0ArenaCap = 8192)
    check host.available
    gPath0 = host.path0
    let (a, b) = collidingPair(cap)
    check a != b
    check (fingerprint(a) or 1'u64) mod uint64(cap) ==
          (fingerprint(b) or 1'u64) mod uint64(cap)   # same home slot
    gThreadElems[0] = @[a]
    gThreadElems[1] = @[b]
    gHookPoint = spBeforeSlotCas
    resetBarrier()

    var t: array[2, Thread[int]]
    createThread(t[0], workerThread, 0)
    createThread(t[1], workerThread, 1)
    check waitArrived(2, 5.0)          # both paused AT the same slot's CAS
    gRelease.store(1)                   # release the race
    joinThread(t[0]); joinThread(t[1])

    # Both distinct elements landed — none lost, none duplicated.
    check gFirstStatus[0] == isInserted
    check gFirstStatus[1] == isInserted
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == toHashSet(@[strOf(a), strOf(b)])
    check host.claimedSlots() == 2      # exactly two slots claimed
    host.assertNoAbsolutePointers()
    host.detach()

# --- (c) double-grow: exactly one shard file, no leaked temp ----------------

suite "double-grow (design spec §4.5(c))":
  test "two producers link a new shard concurrently; one file, no leak":
    let dir = freshDir("doublegrow")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = 16384)
    check host.available
    gPath0 = host.path0
    var expected = initHashSet[string]()
    gThreadElems[0] = @[]
    gThreadElems[1] = @[]
    for i in 0 ..< 60:
      let ea = "A/" & $i
      let eb = "B/" & $i
      expected.incl ea; expected.incl eb
      gThreadElems[0].add bytesOf(ea)
      gThreadElems[1].add bytesOf(eb)
    gHookPoint = spBeforeShardLink
    resetBarrier()

    var t: array[2, Thread[int]]
    createThread(t[0], workerThread, 0)
    createThread(t[1], workerThread, 1)
    # Both threads reach the shard-link publish for the SAME new shard index
    # before either has linked (the pause is before link + before chain-bump).
    check waitArrived(2, 10.0)
    gRelease.store(1)
    joinThread(t[0]); joinThread(t[1])

    # Exactly one shard1 file, and NO leaked temp (the loser cleaned its tmp).
    check countNameContains(dir, ".shardtmp") == 0
    let shard1 = host.path0[0 ..< host.path0.len - ".shard0".len] & ".shard1"
    check fileExists(shard1)
    # The chain is valid and contiguous, and the merged union is exact.
    let n = host.shardCount()
    check n >= 2
    for k in 0 ..< n:
      check fileExists(host.path0[0 ..< host.path0.len - ".shard0".len] &
        ".shard" & $k)
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == expected                # zero loss, zero phantom
    check host.growthFailures() == 0
    host.assertNoAbsolutePointers()
    host.detach()

# --- (c) arena reserve/publish ordering (no torn read) ----------------------

suite "arena reserve/publish ordering (design spec §4.5(c))":
  test "a slot is never visible before its arena bytes are release-published":
    let dir = freshDir("arenapub")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check host.available
    gPath0 = host.path0
    let e = bytesOf("torn-canary-element")
    gThreadElems[0] = @[e]
    gThreadElems[1] = @[]                 # only one producer
    gHookPoint = spBeforeSlotCas
    resetBarrier()

    var t: Thread[int]
    createThread(t, workerThread, 0)
    check waitArrived(1, 5.0)             # producer: arena written, slot NOT yet
                                          # published (paused before the CAS)
    # A concurrent reader must NOT observe the element — the slot is still 0.
    var reader = attachSet(host.path0)
    check reader.available
    check (not reader.contains(e))        # unpublished ⇒ invisible, never torn
    gRelease.store(1)                     # publish it now
    joinThread(t)

    # After the release-CAS the element is atomically visible AND byte-intact.
    check reader.contains(e)
    var got = initHashSet[string]()
    for x in reader.items: got.incl strOf(x)
    check got == toHashSet(@[strOf(e)])
    reader.detach(); host.detach()

# --- (c) reaper vs a run holding shard0's flock -----------------------------

suite "reaper vs starting/active run (design spec §4.5(c))":
  test "a run holding shard0's flock is NOT reaped even when it looks stale":
    let dir = freshDir("reapflock")
    defer: removeDir(dir)
    # Forge a would-be-stale anchor (wrong boot-id ⇒ reapable) but hold its flock,
    # as a run that is just starting / actively owning shard0 would.
    let wrongBoot = bootId() + 1
    let livePid = uint64(getpid())
    let stalePrefix = shardBasePrefix(dir, "io-mon", "startingRun", wrongBoot, livePid)
    let staleAnchor = stalePrefix & ".shard0"
    writeFile(staleAnchor, "starting-run shard0")
    check fileExists(staleAnchor)

    let fd = open(staleAnchor.cstring, O_RDWR)
    check fd >= 0
    check flock(fd, LOCK_EX) == 0        # the owner holds the lock

    # Reaper runs concurrently: the flock guard MUST protect the run.
    check reapStaleSegments(dir, "io-mon") == 0
    check fileExists(staleAnchor)

    # Once the owner releases the lock, the stale run becomes reapable.
    check flock(fd, LOCK_UN) == 0
    discard close(fd)
    check reapStaleSegments(dir, "io-mon") >= 1
    check (not fileExists(staleAnchor))

# --- (d) real multi-process SIGKILL fault injection -------------------------

var gTargetPoint: SchedulePoint
var gKillPipeW: cint
var tReached {.threadvar.}: bool

proc killHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  if p == gTargetPoint and not tReached:
    tReached = true
    var one: byte = 1
    discard write(gKillPipeW, addr one, 1)   # tell the parent "I am AT the point"
    while true: discard sched_yield()          # wait to be SIGKILLed here

proc faultInjectAt(point: SchedulePoint; victimCount: int; label: string) =
  let dir = freshDir("kill-" & label)
  defer: removeDir(dir)
  # Moderate shard0 so the committed producers do NOT grow; the victim forces the
  # first grow itself so it deterministically reaches the shard-link/chain-bump.
  var host = createSet(dir, "io-mon", "edge", shard0Cap = 256, shard0ArenaCap = 64 * 1024)
  doAssert host.available
  let path0 = host.path0

  const nCommit = 3
  const perCommit = 40
  var committed = initHashSet[string]()
  for c in 0 ..< nCommit:
    for j in 0 ..< perCommit: committed.incl("commit" & $c & "/" & $j)

  var cpids: seq[Pid]
  for c in 0 ..< nCommit:
    let pid = fork()
    if pid == 0:
      var s = attachSet(path0)
      if not s.available: quitChild(2)
      for j in 0 ..< perCommit:
        if s.insert(bytesOf("commit" & $c & "/" & $j)) == isUnavailable:
          quitChild(3)
      s.detach(); quitChild(0)
    else:
      doAssert pid > 0
      cpids.add pid
  for pid in cpids:
    var st: cint
    doAssert waitpid(pid, st, 0) == pid
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0, label & ": committed producer failed"

  # Victim: pause at `point`, tell parent, get SIGKILLed there.
  var fds: array[0..1, cint]
  doAssert pipe(fds) == 0
  gTargetPoint = point
  let victim = fork()
  if victim == 0:
    discard close(fds[0])
    gKillPipeW = fds[1]
    var s = attachSet(path0)
    if not s.available: quitChild(2)
    setScheduleHook(killHook)
    for j in 0 ..< victimCount:
      discard s.insert(bytesOf("victim/" & $j))
    s.detach(); quitChild(0)             # (reached only if the point never fired)
  doAssert victim > 0
  discard close(fds[1])

  # Wait (bounded, no hang) for the victim to reach the publish point.
  var one: byte
  let n = read(fds[0], addr one, 1)
  doAssert n == 1, label & ": victim never reached " & $point &
    " (read returned " & $n & ")"
  doAssert kill(victim, SIGKILL) == 0
  var st: cint
  doAssert waitpid(victim, st, 0) == victim
  doAssert WIFSIGNALED(st), label & ": victim was not killed at the point"
  discard close(fds[0])

  # The single-threaded reader's union must be correct:
  var got = initHashSet[string]()
  for e in host.items: got.incl strOf(e)
  # 1. no lost COMMITTED element
  for e in committed:
    doAssert e in got, label & ": lost committed element " & e
  # 2. no phantom / torn read — every element is a real committed or victim key
  for e in got:
    doAssert (e in committed) or e.startsWith("victim/"),
      label & ": phantom/torn element " & e
  # 3. growth failures signalled zero
  doAssert host.growthFailures() == 0, label & ": spurious growth failure"
  # 4. a single unpublished insert killed before its slot-CAS is fully ABSENT
  if point in {spBeforeSlotCas, spBeforeArenaPublish} and victimCount == 1:
    doAssert "victim/0" notin got,
      label & ": an unpublished (killed pre-CAS) element became visible"
  # 5. no absolute-pointer corruption survived the kill
  host.assertNoAbsolutePointers()
  host.detach()

suite "multi-process SIGKILL fault injection (design spec §4.5(d))":
  test "kill at spBeforeArenaPublish (bytes written, slot unpublished)":
    faultInjectAt(spBeforeArenaPublish, 1, "arenaPublish")
  test "kill at spBeforeSlotCas (about to claim the slot)":
    faultInjectAt(spBeforeSlotCas, 1, "slotCas")
  test "kill at spBeforeShardLink (new shard built, not yet linked)":
    faultInjectAt(spBeforeShardLink, 300, "shardLink")
  test "kill at spBeforeChainBump (shard linked, chain-count not bumped)":
    faultInjectAt(spBeforeChainBump, 300, "chainBump")
