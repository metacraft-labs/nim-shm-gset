## Deterministic concurrency verification for `nim-shm-gset` (design spec §4.5).
## Built with `-d:shmGSetScheduleHooks --threads:on`. Every window below is driven
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

import std/[os, sets, strutils, tables, times, unittest, atomics]
import shm_gset
import shm_gset/platform
import ./xproc

static: doAssert scheduleHooksEnabled, "expected -d:shmGSetScheduleHooks"

var tmpCtr = 0
proc freshDir(tag: string): string = freshTestDir("shmgset-cc", tag, tmpCtr)

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
      yieldThread()

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
    yieldThread()
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
    let want = reserveMapBase(sz)
    check want != nil
    # The chosen base must satisfy THIS platform's mapping alignment — 4 KiB on
    # POSIX, 64 KiB on Win32, where a merely page-aligned base is rejected
    # outright. Asserting it here means a future change to `reserveMapBase` that
    # returned an illegal address would fail as an alignment error rather than as
    # a mysterious "attach unavailable".
    check cast[uint](want) mod uint(shmGSetMapBaseAlignment) == 0
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
    let livePid = uint64(ownPid())
    let stalePrefix = shardBasePrefix(dir, "io-mon", 1'u64, wrongBoot, livePid)
    let staleAnchor = stalePrefix & ".shard0"
    writeFile(staleAnchor, "starting-run shard0")
    check fileExists(staleAnchor)

    # The lock is taken through the SAME primitive the reaper uses, so the test
    # exercises the shipped exclusion rather than a lookalike: `flock` on POSIX,
    # `LockFileEx` on Win32.
    let fd = openReadWrite(staleAnchor)
    check fd.isValid
    check tryLockExclusive(fd)           # the owner holds the lock

    # Reaper runs concurrently: the lock guard MUST protect the run.
    check reapStaleSegments(dir, "io-mon") == 0
    check fileExists(staleAnchor)

    # Once the owner releases the lock, the stale run becomes reapable.
    check unlockExclusive(fd)
    closeFile(fd)
    check reapStaleSegments(dir, "io-mon") >= 1
    check (not fileExists(staleAnchor))

# --- (d) real multi-process SIGKILL fault injection -------------------------

var gTargetPoint: SchedulePoint
var tReached {.threadvar.}: bool

# The "I am at the publish point" announcement is a FILE, not a pipe: a FORKED
# child inherits a pipe descriptor and a SPAWNED child does not, whereas a file
# in the test's own directory works identically for both.
#
# The path is a fixed char buffer and the file is created through C `fopen`
# rather than `writeFile`, because the hook is `{.gcsafe, raises: [].}` — it runs
# inside the library's publish path — and a GC'd global string is neither. This
# is the one place in the suite where that matters.
var gReachedPath: array[1024, char]

proc cFopen(path, mode: cstring): pointer {.importc: "fopen",
  header: "<stdio.h>".}
proc cFclose(f: pointer): cint {.importc: "fclose", header: "<stdio.h>".}

proc setReachedPath(path: string) =
  doAssert path.len < gReachedPath.len
  zeroMem(addr gReachedPath[0], gReachedPath.len)
  if path.len > 0: copyMem(addr gReachedPath[0], unsafeAddr path[0], path.len)

proc killHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  ## Announce "I am AT the publish point", then spin here forever waiting to be
  ## destroyed. The marker is written BEFORE the spin, so the parent cannot
  ## observe it until the victim is genuinely parked at the point.
  if p == gTargetPoint and not tReached:
    tReached = true
    let f = cFopen(cast[cstring](addr gReachedPath[0]), "wb".cstring)
    if f != nil: discard cFclose(f)
    while true: yieldThread()            # wait to be killed HERE

proc committedProducer(args: seq[string]) =
  ## A producer that commits its whole intended subset and exits cleanly, so the
  ## oracle has elements that MUST survive the victim's crash.
  let
    path0 = args[0]
    c = parseInt(args[1])
    perCommit = parseInt(args[2])
  var s = attachSet(path0)
  if not s.available: exitChild(2)
  for j in 0 ..< perCommit:
    if s.insert(bytesOf("commit" & $c & "/" & $j)) == isUnavailable:
      exitChild(3)
  s.detach()
  exitChild(0)

proc killVictim(args: seq[string]) =
  ## Insert until the chosen schedule point fires, then park there to be killed.
  ## Reaching the end means the point never fired, and the `finished` marker it
  ## writes is what makes that visible to the parent instead of silent.
  let
    path0 = args[0]
    victimCount = parseInt(args[1])
    point = SchedulePoint(parseInt(args[2]))
    finishedFile = args[4]
  setReachedPath(args[3])
  gTargetPoint = point
  var s = attachSet(path0)
  if not s.available: exitChild(2)
  setScheduleHook(killHook)
  for j in 0 ..< victimCount:
    discard s.insert(bytesOf("victim/" & $j))
  s.detach()
  try: writeFile(finishedFile, "ran-to-completion")
  except CatchableError: discard
  exitChild(0)

registerChildRole("committedProducer", committedProducer)
registerChildRole("killVictim", killVictim)
xprocChildEntry()

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

  var kids: seq[Child]
  for c in 0 ..< nCommit:
    kids.add startChild("committedProducer", path0, c, perCommit)
  for k in kids.mitems:
    doAssert waitChild(k) == 0, label & ": committed producer failed"

  # Victim: park at `point`, tell the parent, and be destroyed THERE.
  let reachedFile = dir / "victim-reached"
  let finishedFile = dir / "victim-finished"
  var victim = startChild("killVictim", path0, victimCount, $int(point),
    reachedFile, finishedFile)

  # Wait (bounded, no hang) for the victim to reach the publish point.
  let deadline = epochTime() + 30.0
  while not fileExists(reachedFile):
    doAssert epochTime() < deadline,
      label & ": victim never reached " & $point
    yieldThread()
  killChild(victim)
  let vst = waitChild(victim)

  # THE EVIDENCE THAT THE KILL LANDED WHERE IT WAS AIMED, stated as two
  # properties rather than as a wait-status encoding: the victim DID reach the
  # publish point (the marker exists) and it did NOT run past it (the marker its
  # normal path writes does not). That is platform-independent, and it is
  # strictly more specific than "the wait status says signalled" — which on its
  # own cannot tell a kill at the point from a kill anywhere else.
  doAssert fileExists(reachedFile), label & ": victim never reached the point"
  doAssert not fileExists(finishedFile),
    label & ": victim ran PAST " & $point & " instead of being killed at it"
  doAssert vst == KilledExitStatus,
    label & ": victim exited " & $vst & " rather than being killed"

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
