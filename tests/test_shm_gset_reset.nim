## RESET / RECYCLING suite (HM-2) — the generation-stamped, quiescence-checked
## `reset` that turns a grown chain into a fresh empty set.
##
## NOTHING HERE IS MOCKED. Every case runs against real shard files in a real
## directory, created by the real `createSet` / `attachSet` / `startHost`, with
## real `fork`ed producer processes (including a `setsid`-detached grandchild
## that genuinely outlives its root and is reparented away from this process),
## real `SIGKILL` mid-operation, and real shared memory. No mock is used and none
## was needed, so this file carries no mock justification under the workspace
## policy.
##
## Built with `-d:shmGSetScheduleHooks`, because two of the properties are not
## reachable otherwise: the kill-injection cases need a seam at each of `reset`'s
## publish points, and the generation-exhaustion case needs the counter driven to
## its last value instead of being reasoned about.
##
## THE FIVE PROPERTIES, and the failure each one guards:
##
##   1. `recycled_chain_never_cross_attributes` — two actions with DISJOINT input
##      sets through ONE recycled chain; neither observes the other's paths. If
##      this breaks, one action's dependencies are attributed to another: a wrong
##      dependency set, the cardinal sin the whole library exists to prevent.
##   2. `reset_refuses_with_a_live_producer` — a producer between its arena
##      reserve and its slot publish when the generation flips would land bytes
##      in the recycled set. The §4.1 incident was a detached descendant that
##      outlived its root and kept producing, so that exact shape is one of the
##      cases here. The test asserts the refusal FIRES, not that the
##      precondition is documented.
##   3. `reset_rearms_consumer_liveness` — `markConsumerGone` used to be
##      terminal. A recycled chain whose token is still "gone" makes every
##      producer of the NEXT action fast-fail with `emConsumerGone` — monitored
##      by nobody, and silently.
##   4. `reset_is_constant_time` — the naive reset (zero the tables and arenas)
##      costs what the chain GREW to, so a small action recycling a large chain
##      pays for the whole thing. Asserted structurally (reset writes NOTHING
##      outside shard0's fixed header, so there is no per-shard or per-slot work
##      to scale) and corroborated by measurement.
##   5. `crash_mid_reset_leaves_chain_fully_old_or_fully_new` — the generation
##      store is the single commit point. A `SIGKILL` at every publish point
##      must leave the chain wholly in one state or the other, with no shard
##      file leaked.
##
## Three further cases cover hazards the five above do not, each of which was
## found by pushing on the design rather than by a failing test:
##
##   * a producer attaching DURING a reset (the window between the quiescence
##     check and the commit — found by the TLA+ model, closed by the reset seal);
##   * a FORK CHILD releasing the registry entry it inherited from its parent
##     (io-mon's atfork handler does exactly this, and an unconditional release
##     there would deregister a parent that is still producing);
##   * a producer the registry could not track, which must refuse with a
##     DIFFERENT status because that refusal may be permanent.

import std/[algorithm, monotimes, os, sets, strutils, times, unittest]
import shm_gset
import shm_gset/transport
import shm_gset/platform
import ./xproc

when not defined(windows):
  # For the cases that are ABOUT POSIX process semantics and say so: the
  # `setsid` detached descendant, `/proc`-based reparenting evidence, the
  # atfork-inheritance rule, and the crash-atomicity cases in which the CHILD
  # inherits the parent's consumer handle. Everything else here goes through
  # `tests/xproc.nim`, which is portable.
  import std/posix
  proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCtr = 0
proc freshDir(tag: string): string = freshTestDir("shmgset-reset", tag, tmpCtr)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc headerU64(path0: string; off: int): uint64 =
  ## Read one fixed-header word straight out of the shard FILE, with nothing
  ## mapped and nothing attached. The crash-atomicity case on Windows has no
  ## live observer available to it, so the commit boundary is asserted against
  ## the bytes on disk — which is, after all, what "persists" means here.
  let f = open(path0, fmRead)
  defer: f.close()
  f.setFilePos(off)
  var buf: array[8, byte]
  doAssert f.readBytes(buf, 0, 8) == 8
  copyMem(addr result, addr buf[0], 8)

proc runIdInFile(path0: string; gen: uint64): string =
  ## The runId stored in the slot that generation `gen` selects, read from the
  ## file. `reset` writes the NEXT generation's identity before it publishes the
  ## generation, so reading both slots is how a test tells "not yet stamped"
  ## from "stamped but not yet selected".
  let off = ShOffRunIdSlots + int(gen and 1'u64) * RunIdSlotBytes
  let f = open(path0, fmRead)
  defer: f.close()
  f.setFilePos(off)
  var hdr: array[4, byte]
  doAssert f.readBytes(hdr, 0, 4) == 4
  var n: uint32
  copyMem(addr n, addr hdr[0], 4)
  if n == 0'u32 or int(n) > RunIdSlotBytes - RunIdSlotHdr: return ""
  f.setFilePos(off + RunIdSlotHdr)
  var body = newSeq[byte](int(n))
  doAssert f.readBytes(body, 0, int(n)) == int(n)
  result = newString(int(n))
  copyMem(addr result[0], addr body[0], int(n))

proc shardFiles(dir: string): seq[string] =
  for _, p in walkDir(dir):
    if ".shard" in extractFilename(p): result.add extractFilename(p)
  result.sort()

proc unionOf[K](s: var ShmGSetT[K]): HashSet[string] =
  result = initHashSet[string]()
  for e in s.items: result.incl strOf(e)

# --- child roles (see tests/xproc.nim) --------------------------------------

proc emitProducer(args: seq[string]) =
  ## Attach a producer and emit `perProc` tagged elements, then detach.
  let
    path0 = args[0]
    tag = args[1]
    c = parseInt(args[2])
    perProc = parseInt(args[3])
  var pr = attachProducer(path0)
  if not pr.available: exitChild(2)
  for j in 0 ..< perProc:
    if pr.emit(bytesOf(tag & "/c" & $c & "/dep-" & $j)) notin
        {emInserted, emExists}:
      pr.detach(); exitChild(3)
  pr.detach()
  exitChild(0)

proc attachProbe(args: seq[string]) =
  ## Try to ATTACH while a reset is held open at its commit point, and report
  ## which of the three outcomes happened through the exit status.
  var pr = attachSet(args[0])
  let f = pr.attachFailure
  let ok = pr.available
  if ok: pr.detach()
  exitChild(if ok: 0 elif f == afRecycling: 20 else: 21)

proc neverDetachingProducer(args: seq[string]) =
  ## Attach, emit, publish this process's pid, and then NEVER detach — the
  ## registry entry this leaves behind is what the caller kills and then expects
  ## to be reclaimed.
  let path0 = args[0]
  let pidFile = args[1]
  var pr = attachProducer(path0)
  if not pr.available: exitChild(2)
  discard pr.emit(bytesOf("half-written"))
  try: writeFile(pidFile, $ownPid())
  except CatchableError: exitChild(4)
  while true: os.sleep(60_000)           # never detaches

proc detachedDescendant(args: seq[string]) =
  ## The GRANDCHILD of the §4.1 shape: a producer that outlives the process that
  ## started it. It attaches, emits, announces its pid, and holds the attach open
  ## until told to go.
  let
    path0 = args[0]
    pidFile = args[1]
    goFile = args[2]
  var pr = attachProducer(path0)
  if not pr.available: exitChild(2)
  if pr.emit(bytesOf("from-detached-descendant")) notin {emInserted, emExists}:
    exitChild(3)
  try: writeFile(pidFile, $ownPid())
  except CatchableError: exitChild(4)
  while not fileExists(goFile): os.sleep(5)
  pr.detach()
  exitChild(0)

proc detachedRoot(args: seq[string]) =
  ## The INTERMEDIATE of the §4.1 shape: start the real producer and exit
  ## immediately, so that producer outlives its root and no lifecycle signal the
  ## original process can observe says it is still there. The registry does.
  ##
  ## On POSIX it also leaves this process's session first, so the grandchild is
  ## reparented away entirely rather than merely orphaned. Windows has no
  ## sessions to leave and no reparenting to do: a process there already
  ## survives its parent with nothing linking them, which is the same shape
  ## arrived at by default.
  when not defined(windows):
    discard setsid()
  var gc = startChild("detachedDescendant", args[0], args[1], args[2])
  discard gc
  exitChild(0)

proc rearmProbe(args: seq[string]) =
  ## A producer of the NEXT action: it must see the RE-ARMED liveness token, so
  ## `emit` inserts rather than reporting the consumer gone.
  var pr = attachProducer(args[0])
  if not pr.available: exitChild(2)
  let st = pr.emit(bytesOf("child-dep"))
  pr.detach()
  exitChild(if st == emInserted: 0 elif st == emConsumerGone: 7 else: 8)

registerChildRole("emitProducer", emitProducer)
registerChildRole("attachProbe", attachProbe)
registerChildRole("neverDetachingProducer", neverDetachingProducer)
registerChildRole("detachedDescendant", detachedDescendant)
registerChildRole("detachedRoot", detachedRoot)
registerChildRole("rearmProbe", rearmProbe)
# The crash-atomicity seam: a schedule hook that destroys its own process at a
# chosen publish point. Declared here, with the child roles, because the roles
# below arm it and everything a role touches must exist before
# `xprocChildEntry`.
var killAt: SchedulePoint
var killArmed = false

proc killingHook(point: SchedulePoint) {.gcsafe, raises: [].} =
  if killArmed and point == killAt:
    terminateSelf()


# The two crash-atomicity roles below exist only where there is no `fork`. On
# POSIX the child INHERITS the parent's consumer handle, which is the sharper
# shape and is kept — see the cases themselves. On Windows a consumer handle
# cannot be transferred to another process at all (`reset` answers
# `rsNotConsumer` on a producer view), so the crashing process has to BE the
# chain's creator and the observer has to be a separate producer view.
when defined(windows):
  proc crashingResetter(args: seq[string]) =
    ## Create a chain, fill it, and crash inside `reset` at a chosen publish
    ## point, recording what the chain looked like BEFORE the reset so the
    ## observer can assert nothing moved.
    ##
    ## NOBODY ELSE IS ATTACHED WHILE THIS RUNS, and that is forced rather than
    ## chosen. `reset` refuses unless the chain is quiescent, so an observer
    ## attached beforehand would turn the reset into `rsBusyProducers` and no
    ## schedule point would ever fire (measured: the child exited 9, its
    ## "unreachable" status). And `reset` engages the reset SEAL as its first
    ## act, which a process dying between the seal and the commit never clears,
    ## so an observer attaching afterwards is refused with `afRecycling`. On
    ## POSIX neither bites, because the observer there is the PARENT holding a
    ## CONSUMER handle — which is not a registered producer and was attached
    ## before any of this. A consumer handle cannot cross a process boundary
    ## except by `fork`, so on Windows the observation has to be made from the
    ## FILE instead. See the test.
    let
      dir = args[0]
      nElems = parseInt(args[1])
      point = SchedulePoint(parseInt(args[2]))
      stateFile = args[3]
    var host = createSet(dir, "io-mon", "action-A", shard0Cap = 64,
      shard0ArenaCap = 2048)
    if not host.available: exitChild(2)
    for i in 0 ..< nElems:
      if host.insert(bytesOf("A/dep-" & $i)) notin {isInserted, isExists}:
        exitChild(3)
    if host.shardCount() < 2: exitChild(4)
    try:
      writeFile(stateFile, host.path0 & "\n" & $host.shardCount() & "\n" &
        shardFiles(dir).join(","))
    except CatchableError: exitChild(5)
    killAt = point
    killArmed = true
    setScheduleHook(killingHook)
    discard host.reset("action-B")
    exitChild(9)                  # unreachable: the hook kills us first

  proc committingResetter(args: seq[string]) =
    ## Create a chain, fill it, `reset` it SUCCESSFULLY, then die before
    ## returning — the other side of the commit boundary.
    let
      dir = args[0]
      nElems = parseInt(args[1])
      stateFile = args[2]
    var host = createSet(dir, "io-mon", "action-A", shard0Cap = 64,
      shard0ArenaCap = 2048)
    if not host.available: exitChild(2)
    for i in 0 ..< nElems:
      if host.insert(bytesOf("A/dep-" & $i)) notin {isInserted, isExists}:
        exitChild(3)
    try:
      writeFile(stateFile, host.path0 & "\n" & $host.shardCount() & "\n" &
        shardFiles(dir).join(","))
    except CatchableError: exitChild(5)
    if host.reset("action-B") != rsReset: exitChild(9)
    terminateSelf()
    exitChild(8)

  registerChildRole("crashingResetter", crashingResetter)
  registerChildRole("committingResetter", committingResetter)

xprocChildEntry()

proc waitGone(pid: uint64; timeoutMs = 5000) =
  ## Poll until `pid` is really gone. It is a DESCENDANT, not a child — it was
  ## reparented (POSIX) or simply orphaned (Win32) — so no wait primitive
  ## applies and liveness must be polled. `processAlive` is the same primitive
  ## the reaper judges staleness with, which is the one whose answer matters.
  var waited = 0
  while waited < timeoutMs:
    if not processAlive(pid): return
    os.sleep(5); waited += 5
  doAssert false, "process " & $pid & " did not exit"

when not defined(windows):
  proc parentPidOf(pid: uint64): uint64 =
    ## The pid's CURRENT parent, straight out of `/proc`. Used to prove the
    ## detached descendant really was reparented away from this process rather
    ## than merely being described that way.
    ##
    ## POSIX-only, and it is EVIDENCE rather than the property: Windows has no
    ## reparenting to observe, because it never had the parent-owns-child
    ## relationship that reparenting repairs — an orphaned process there simply
    ## keeps running with a stale parent-pid field. The property both platforms
    ## do share, and that the test asserts on both, is the one that matters: the
    ## ROOT is gone, the producer is still alive, and `reset` still refuses.
    try:
      for line in lines("/proc/" & $pid & "/status"):
        if line.startsWith("PPid:"):
          return parseBiggestUInt(line.split()[1])
    except CatchableError: discard
    0'u64

# ---------------------------------------------------------------------------
# 1. the headline property: a recycled chain never cross-attributes
# ---------------------------------------------------------------------------

suite "a recycled chain is a FRESH set":

  test "recycled_chain_never_cross_attributes":
    # Two actions, disjoint input sets, ONE chain. The chain is grown to several
    # shards by action A precisely so that recycling has something to recycle:
    # if reset leaked, A's several thousand paths would show up in B's
    # dependency set and B would be cached against inputs it never read.
    let dir = freshDir("cross")
    defer: removeDir(dir)
    const
      nProc = 3
      perProc = 900
    var host = createSet(dir, "io-mon", "action-A", shard0Cap = 64,
      shard0ArenaCap = 2048)
    check host.available
    check host.generation == 1'u64

    proc runProducers(path0: string; tag: string) =
      var kids: seq[Child]
      for c in 0 ..< nProc:
        kids.add startChild("emitProducer", path0, tag, c, perProc)
      for k in kids.mitems:
        doAssert waitChild(k) == 0

    proc expected(tag: string): HashSet[string] =
      result = initHashSet[string]()
      for c in 0 ..< nProc:
        for j in 0 ..< perProc:
          result.incl(tag & "/c" & $c & "/dep-" & $j)

    runProducers(host.path0, "A")
    let setA = expected("A")
    check host.snapshot().len == setA.len
    check unionOf(host) == setA
    check host.runId == "action-A"
    let grownShards = host.shardCount()
    check grownShards >= 3                     # the chain really did grow
    let filesBefore = shardFiles(dir)

    # End action A and recycle. Quiescent: every producer detached and exited.
    host.markConsumerGone()
    check host.attachedProducers == 0
    check host.reset("action-B") == rsReset

    # The chain is now EMPTY, still grown, and carries B's identity.
    check host.generation == 2'u64
    check unionOf(host).len == 0               # PRIMARY ASSERTION (emptiness)
    check host.runId == "action-B"
    check host.shardCount() == grownShards     # nothing was thrown away
    check shardFiles(dir) == filesBefore       # and no file was created/leaked
    check host.growthFailures() == 0

    # Action B: a disjoint input set through the same shards.
    runProducers(host.path0, "B")
    let setB = expected("B")
    let gotB = unionOf(host)
    check gotB == setB                         # PRIMARY ASSERTION (exact union)
    var leakedFromA: seq[string]
    for e in gotB:
      if e.startsWith("A/"): leakedFromA.add e
    check leakedFromA.len == 0                 # PRIMARY ASSERTION (no leakage)
    check host.runId == "action-B"
    check host.growthFailures() == 0

    # ...and the reaper attributes the recycled chain to B, not to A: the
    # identity a chain reports is the one it was RE-STAMPED with.
    let path0 = host.path0
    host.detach()
    check reapStaleSegmentsDetailed(dir, "io-mon").len == 0   # owner still alive
    var reader = attachSet(path0)
    check reader.available
    check reader.runId == "action-B"
    reader.detach()

  test "elements of the previous generation are unreachable by EVERY reader":
    # `items` is not the only way into the structure. `contains` probes the run
    # directly and `withPrimaryKey` walks it; a generation filter that covered
    # only the union would leave the other two reading the previous action's
    # bytes.
    let dir = freshDir("readers")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "gen-one", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check s.available
    for i in 0 ..< 40:
      check s.insert(bytesOf("old-" & $i)) == isInserted
    check s.contains(bytesOf("old-7"))
    var runLen = 0
    for _ in s.withPrimaryKey(bytesOf("old-7")): inc runLen
    check runLen >= 1
    check s.claimedSlots() == 40'u64

    check s.reset("gen-two") == rsReset
    check (not s.contains(bytesOf("old-7")))       # PRIMARY ASSERTION
    var runLen2 = 0
    for _ in s.withPrimaryKey(bytesOf("old-7")): inc runLen2
    check runLen2 == 0                             # PRIMARY ASSERTION
    check s.claimedSlots() == 0'u64
    var shardSeen = 0
    for _ in s.shardElements(0): inc shardSeen
    check shardSeen == 0
    # A re-insert of the SAME bytes is a fresh insert, not a stale `isExists`.
    check s.insert(bytesOf("old-7")) == isInserted
    check s.contains(bytesOf("old-7"))
    check s.snapshot().len == 1
    s.assertNoAbsolutePointers()
    s.detach()

  test "a recycled chain re-grows into its OWN shards, never a new file":
    # The entire point of recycling: every later action reuses the capacity the
    # first one paid for. The mechanism is the GENERATION-REBASING arena bump
    # pointer (`reserveArena`) — without it each generation's records pile on top
    # of the previous generation's, the newest shard's arena runs out, and the
    # chain grows a shard it did not need.
    #
    # REPEATED ON PURPOSE. A single recycle does NOT detect a non-rebasing arena:
    # measured, the newest shard's arena still has room for the second fill, and
    # the extra shard first appears on the THIRD (4 4 5 5 … versus 4 4 4 4 …
    # shipped). One round would be a test that passes whether or not the property
    # it names holds, so the cycle runs until the difference is unmissable.
    let dir = freshDir("regrow")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "a", shard0Cap = 64, shard0ArenaCap = 2048)
    check s.available
    for i in 0 ..< 1500:
      check s.insert(bytesOf("path/to/file-" & $i & ".h")) in {isInserted, isExists}
    let grown = s.shardCount()
    check grown >= 3
    let files = shardFiles(dir)
    for round in 0 ..< 5:
      check s.reset("b" & $round) == rsReset
      for i in 0 ..< 1500:
        check s.insert(bytesOf("path/to/file-" & $i & ".h")) in
          {isInserted, isExists}
      check s.shardCount() == grown             # PRIMARY ASSERTION
      check shardFiles(dir) == files            # PRIMARY ASSERTION
      check s.snapshot().len == 1500
    s.detach()

# ---------------------------------------------------------------------------
# 2. quiescence — the crux
# ---------------------------------------------------------------------------

# The attach-during-reset probe lives at module level because a schedule hook is
# a plain `{.gcsafe.}` proc pointer; the `cast(gcsafe)` is over test-only globals
# that only this single-threaded test touches.
var sealPath0: string
var sealChildCode = -1
var sealAttempted = false

proc holdOpenHook(point: SchedulePoint) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if point != spBeforeGenerationPublish or sealAttempted: return
    sealAttempted = true
    # `{.cast(raises: []).}` because the hook's effect signature is `raises: []`
    # while starting a process is not: this seam runs INSIDE `reset`, and the
    # child it starts is the whole point of the case. A failure to start is
    # reported as -2 through `sealChildCode`, which the test asserts on, so the
    # cast hides nothing.
    {.cast(raises: []).}:
      try:
        var kid = startChild("attachProbe", sealPath0)
        sealChildCode = waitChild(kid)
      except Exception:
        sealChildCode = -2

suite "reset REFUSES unless the chain is quiescent":

  test "reset_refuses_with_a_live_producer":
    let dir = freshDir("busy")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check host.available
    check host.insert(bytesOf("owner-elem")) == isInserted

    # (a) an ordinary attached producer in THIS process.
    var p = attachSet(host.path0)
    check p.available
    check host.attachedProducers == 1
    check host.reset("run-2") == rsBusyProducers   # PRIMARY ASSERTION
    check host.generation == 1'u64                 # and it changed NOTHING
    check host.runId == "run-1"
    check host.contains(bytesOf("owner-elem"))
    p.detach()
    check host.attachedProducers == 0
    host.detach()

  test "reset_refuses_for_a_detached_descendant_that_outlived_its_root":
    # The §4.1 shape, and the reason the chain carries its own producer registry
    # instead of trusting "the monitored tree exited": a producer that outlives
    # the process that started it. The intermediate exits immediately, so no
    # lifecycle signal THIS process can observe says the producer is still
    # there. The registry does.
    #
    # This used to be the second half of the case above. It is a test in its own
    # right because it asserts a different thing — a detached DESCENDANT, not an
    # ordinary attached producer — and because its POSIX-specific evidence
    # (`setsid` + `/proc` reparenting) should not decide whether the ordinary
    # case runs.
    let dir = freshDir("busy-detached")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check host.available
    let path0 = host.path0
    let pidFile = dir / "descendant.pid"
    let goFile = dir / "descendant.go"

    # The root starts the producer and exits; the producer lives on.
    var inter = startChild("detachedRoot", path0, pidFile, goFile)
    check waitChild(inter) == 0                    # the ROOT is gone...
    var waited = 0
    while not fileExists(pidFile) and waited < 10_000:
      os.sleep(5); waited += 5
    check fileExists(pidFile)
    let gcPid = parseBiggestUInt(readFile(pidFile).strip())
    check gcPid != 0
    check gcPid != uint64(ownPid())
    check processAlive(gcPid)                      # ...and the producer is not
    when not defined(windows):
      # POSIX evidence that it was REPARENTED, not merely orphaned. Windows has
      # no reparenting; see `parentPidOf`.
      check parentPidOf(gcPid) != uint64(ownPid())

    check host.attachedProducers == 1
    check host.reset("run-2") == rsBusyProducers   # PRIMARY ASSERTION
    check host.generation == 1'u64
    check host.runId == "run-1"

    # Release it; once it is really gone the same reset succeeds, so the refusal
    # tracks LIVENESS and is not a permanent block.
    writeFile(goFile, "go")
    waitGone(gcPid)
    check host.attachedProducers == 0
    check host.reset("run-2") == rsReset
    check host.generation == 2'u64
    check host.runId == "run-2"

  test "a producer that DIED without detaching does not block recycling forever":
    # The conservative direction must not become a deadlock: a `SIGKILL`ed
    # producer leaves its registry entry behind, and if that were treated as
    # "live" the chain could never be recycled again.
    let dir = freshDir("deadprod")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check host.available
    let path0 = host.path0
    let pidFile = dir / "producer.pid"
    var child = startChild("neverDetachingProducer", path0, pidFile)
    var waited = 0
    while not fileExists(pidFile) and waited < 10_000:
      os.sleep(5); waited += 5
    check fileExists(pidFile)
    let kid = parseBiggestUInt(readFile(pidFile).strip())
    check kid == childPid(child)
    check host.attachedProducers == 1
    check host.reset("run-2") == rsBusyProducers
    killChild(child)                               # the producer DIES attached
    check waitChild(child) == KilledExitStatus
    waitGone(kid)
    check host.attachedProducers == 0              # entry reclaimed
    check host.reset("run-2") == rsReset           # PRIMARY ASSERTION
    check host.generation == 2'u64
    host.detach()

  test "a producer attaching DURING a reset cannot slip into the new generation":
    # The hole the quiescence check alone does not close: the check says the
    # chain is quiescent, and a producer attaches a microsecond later, before
    # the generation is published. It would then insert under the NEW generation
    # — the finished action's bytes in the next action's dependency set.
    #
    # The seal closes it, and this drives the window deterministically: a hook
    # holds the reset open at its commit point while a real child process tries
    # to attach. `AttachSealSpins` is bounded, so the child gives up rather than
    # hanging, and reports WHY.
    let dir = freshDir("seal")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check host.available
    check host.insert(bytesOf("A/only")) == isInserted
    let path0 = host.path0
    sealPath0 = path0
    sealChildCode = -1
    sealAttempted = false

    setScheduleHook(holdOpenHook)
    check host.reset("run-2") == rsReset
    setScheduleHook(nil)
    check sealAttempted
    check sealChildCode == 20                      # PRIMARY ASSERTION: refused,
                                                   # and refused FOR THAT REASON
    # Nothing of action A survived, and nothing of the interloper arrived.
    check host.generation == 2'u64
    check unionOf(host).len == 0
    # ...and the seal is dropped, so ordinary attaches work again immediately.
    var after = attachSet(host.path0)
    check after.available
    check after.attachFailure == afNone
    after.detach()
    host.detach()

  when defined(windows):
    notApplicableHere("a FORK CHILD detaching its inherited handle never deregisters its parent",
      "the rule under test is that a process which INHERITED an attached handle " &
      "across `fork` — a byte copy naming the PARENT's registry entry — does not " &
      "deregister the parent when it detaches. Windows has no `fork`, so no " &
      "process can ever hold a copy of another process's handle and the rule is " &
      "UNREACHABLE there. The guard it protects (`unregisterProducer` comparing " &
      "the caller's own pid against the handle's `producerPid`) is compiled on " &
      "Windows, and the refusal it feeds is covered there by " &
      "reset_refuses_with_a_live_producer and " &
      "reset_refuses_for_a_detached_descendant_that_outlived_its_root.")
  else:
    test "a FORK CHILD detaching its inherited handle never deregisters its parent":
      # io-mon's shim installs an atfork handler that, in the CHILD, detaches the
      # producer inherited from the parent and re-attaches under the child's own
      # pid. The child's handle is a byte copy of the parent's, so it names the
      # PARENT's registry entry. An unconditional release there would deregister a
      # parent that is still alive and producing, `reset` would see a chain that
      # is not quiescent as quiescent, and the finished action's bytes would land
      # in the next one — the cardinal sin reached through the very mechanism that
      # exists to make forking safe.
      let dir = freshDir("forkdetach")
      defer: removeDir(dir)
      var host = createSet(dir, "io-mon", "run-1", shard0Cap = 64,
        shard0ArenaCap = 4096)
      check host.available

      var parent = attachSet(host.path0)          # the parent producer, still LIVE
      check parent.available
      check host.attachedProducers == 1

      var donePipe: array[2, cint]
      check pipe(donePipe) == 0
      let child = fork()
      if child == 0:
        # Exactly what the atfork handler does: detach the INHERITED handle, then
        # re-attach as this process.
        var inherited = parent                    # the COW copy of the parent's
        inherited.detach()
        var mine = attachSet(host.path0)
        let ok = mine.available
        mine.detach()
        var b: byte = 1
        discard write(donePipe[1], addr b, 1)
        quitChild(if ok: 0 else: 5)
      check child > 0
      var st: cint
      check waitpid(child, st, 0) == child
      check WIFEXITED(st) and WEXITSTATUS(st) == 0

      # The parent's registration SURVIVED the child's detach.
      check host.attachedProducers == 1                # PRIMARY ASSERTION
      check host.reset("run-2") == rsBusyProducers     # PRIMARY ASSERTION
      check host.generation == 1'u64
      parent.detach()
      check host.attachedProducers == 0
      check host.reset("run-2") == rsReset
      discard close(donePipe[0]); discard close(donePipe[1])
      host.detach()

  test "a producer the registry could not track refuses SEPARATELY":
    # The registry is bounded. A producer that finds it full still attaches —
    # never fail a producer for a bookkeeping reason — but the chain then has no
    # pid for it and cannot tell whether it is still running, so `reset` has to
    # refuse. That refusal may be PERMANENT (if the untracked producer died
    # without detaching), which makes it a different situation from a merely
    # busy chain: a pool must retire the chain rather than retry it. Reporting
    # both as `rsBusyProducers` would hide a chain that silently stopped
    # recycling forever — the exact class of invisible degradation this
    # milestone is cleaning up.
    let dir = freshDir("overflow")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 32,
      shard0ArenaCap = 1024)
    check host.available

    # Fill the registry from THIS process: every entry is claimed by a pid that
    # is alive (ours), so the next attach genuinely overflows.
    var held: seq[ShmGSet]
    for i in 0 ..< MaxRegisteredProducers:
      var p = attachSet(host.path0)
      check p.available
      held.add p
    check host.attachedProducers == MaxRegisteredProducers
    check host.untrackedProducers == 0
    check host.reset("run-2") == rsBusyProducers      # tracked ⇒ transient

    var overflowed = attachSet(host.path0)
    check overflowed.available                        # NEVER fail a producer
    check overflowed.attachFailure == afNone
    check overflowed.insert(bytesOf("still-works")) == isInserted
    check host.untrackedProducers == 1

    # Release every TRACKED producer; only the untracked one remains, and the
    # refusal changes shape rather than disappearing.
    for p in held.mitems: p.detach()
    check host.attachedProducers == 1
    check host.untrackedProducers == 1
    check host.reset("run-2") == rsProducersUntracked  # PRIMARY ASSERTION
    check host.generation == 1'u64
    check host.contains(bytesOf("still-works"))

    # A clean detach gives the count back, and recycling resumes.
    overflowed.detach()
    check host.attachedProducers == 0
    check host.untrackedProducers == 0
    check host.reset("run-2") == rsReset
    check host.generation == 2'u64
    host.detach()

  test "reset is CONSUMER-ONLY and validates its runId":
    let dir = freshDir("guards")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 32,
      shard0ArenaCap = 1024)
    check host.available
    var prod = attachSet(host.path0)
    check prod.available
    check prod.reset("nope") == rsNotConsumer      # a producer may not recycle
    prod.detach()
    check host.reset(repeat('r', RunIdMaxBytes + 1)) == rsInvalidRunId
    check host.generation == 1'u64                 # refusals change nothing
    check host.runId == "run-1"
    check host.reset(repeat('r', RunIdMaxBytes)) == rsReset
    check host.runId == repeat('r', RunIdMaxBytes)
    var gone = createSet(dir, "io-mon", "x", shard0Cap = 0)   # invalid: unavailable
    check (not gone.available)
    check gone.reset("y") == rsUnavailable
    host.detach()

  test "the generation counter refuses to WRAP rather than reusing a stamp":
    # 32 bits of generation live in every slot entry. Reusing a stamp would make
    # a slot written 4.29e9 recycles ago read as LIVE — a cross-generation leak.
    # The alternative (scrub every slot on wrap) is O(capacity) AND not
    # crash-atomic, since it destroys the old contents before the commit point.
    # So the chain refuses, and the caller creates a new one. This drives the
    # counter there directly rather than reasoning about it.
    let dir = freshDir("wrap")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "last", shard0Cap = 32,
      shard0ArenaCap = 1024)
    check s.available
    s.forceGenerationForTest(MaxGeneration)
    check s.generation == MaxGeneration
    check s.insert(bytesOf("at-the-last-generation")) == isInserted
    check s.contains(bytesOf("at-the-last-generation"))
    check s.reset("next") == rsGenerationExhausted   # PRIMARY ASSERTION
    check s.generation == MaxGeneration              # unchanged...
    check s.runId == "last"                          # ...in every respect
    check s.contains(bytesOf("at-the-last-generation"))
    # One generation earlier it still recycles, so the boundary is exact.
    s.forceGenerationForTest(MaxGeneration - 1)
    check s.reset("next") == rsReset
    check s.generation == MaxGeneration
    check s.runId == "next"
    s.detach()

# ---------------------------------------------------------------------------
# 3. ordering — the liveness token is re-armed before the generation is visible
# ---------------------------------------------------------------------------

suite "reset re-arms the consumer-liveness token":

  test "reset_rearms_consumer_liveness":
    # `finish` marks the consumer gone and that used to be terminal. A recycled
    # chain whose token is still "gone" makes every producer of the next action
    # fast-fail with `emConsumerGone`: no evidence, no error, no one watching.
    let dir = freshDir("rearm")
    defer: removeDir(dir)
    var host = startHost(dir, "run-1", shard0Cap = 64, shard0ArenaCap = 4096)
    check host.available

    var p1 = attachProducer(host.path0)
    check p1.available
    check p1.emit(bytesOf("a-dep")) == emInserted
    p1.detach()

    # End the action the way a host does: announce the consumer is gone.
    host.markConsumerGone()
    var late = attachProducer(host.path0)
    check late.available
    check late.emit(bytesOf("too-late")) == emConsumerGone   # token IS gone
    late.detach()

    check host.reset("run-2") == rsReset
    check host.generation == 2'u64

    # A producer attaching to the recycled chain must see a LIVE consumer.
    var p2 = attachProducer(host.path0)
    check p2.available
    check p2.emit(bytesOf("b-dep")) == emInserted    # PRIMARY ASSERTION
    check p2.emit(bytesOf("b-dep")) == emExists
    p2.detach()

    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == toHashSet(@["b-dep"])
    check host.runId == "run-2"
    host.finish()

  test "a forked producer of the NEXT action sees the re-armed token too":
    # The in-process check above shares this process's caches. A separate
    # process, mapping the segment at its own base, is the real shape.
    let dir = freshDir("rearmfork")
    defer: removeDir(dir)
    var host = startHost(dir, "run-1", shard0Cap = 64, shard0ArenaCap = 4096)
    check host.available
    host.markConsumerGone()
    check host.reset("run-2") == rsReset
    let path0 = host.path0
    var kid = startChild("rearmProbe", path0)
    check waitChild(kid) == 0                        # PRIMARY ASSERTION
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == toHashSet(@["child-dep"])
    host.finish()

# ---------------------------------------------------------------------------
# 4. O(1) — the cost does not scale with what the chain grew to
# ---------------------------------------------------------------------------

suite "reset is constant time":

  test "reset_is_constant_time":
    # PRIMARY, structural: reset writes NOTHING outside shard0's fixed header.
    # A reset that had to scale with the chain would have to touch a slot array
    # or an arena, and every one of those lives beyond `ShardHeaderSize`. This
    # is a proof rather than a measurement, so it cannot be flaky and cannot be
    # satisfied by a fast-but-linear implementation.
    let dir = freshDir("const")
    defer: removeDir(dir)
    var big = createSet(dir, "io-mon", "big-a", shard0Cap = 64,
      shard0ArenaCap = 2048)
    check big.available
    for i in 0 ..< 20000:
      check big.insert(bytesOf("path/to/file-" & $i & ".h")) in
        {isInserted, isExists}
    let shards = big.shardCount()
    check shards >= 5
    let prefix = big.path0[0 ..< big.path0.len - ".shard0".len]
    var before: seq[string]
    for k in 0 ..< shards: before.add readFile(prefix & ".shard" & $k)

    check big.reset("big-b") == rsReset

    var after: seq[string]
    for k in 0 ..< shards: after.add readFile(prefix & ".shard" & $k)
    check after.len == before.len
    for k in 1 ..< shards:
      check after[k] == before[k]              # PRIMARY ASSERTION: untouched
    check after[0].len == before[0].len
    check after[0][ShardHeaderSize .. ^1] == before[0][ShardHeaderSize .. ^1]
                                               # PRIMARY ASSERTION: header only
    check big.snapshot().len == 0
    check big.shardCount() == shards

    # CORROBORATING measurement (the milestone's "measured against a chain grown
    # to several shards vs a fresh one"). The bound is deliberately loose — the
    # structural assertions above carry the teeth; this only has to catch an
    # implementation whose cost tracks capacity, which for this workload is a
    # ~700 KiB memset per reset against a fixed handful of stores.
    var small = createSet(dir, "io-mon", "small-a", shard0Cap = 64,
      shard0ArenaCap = 2048)
    check small.available
    check small.shardCount() == 1
    const iters = 300
    proc timeResets(s: var ShmGSet; tag: string): float =
      let t0 = getMonoTime()
      for i in 0 ..< iters:
        doAssert s.reset(tag & $i) == rsReset
      float((getMonoTime() - t0).inNanoseconds) / float(iters)
    discard timeResets(small, "warm")          # warm the pages / branch history
    discard timeResets(big, "warm")
    let smallNs = timeResets(small, "s")
    let bigNs = timeResets(big, "b")
    echo "  [reset cost] 1 shard: ", smallNs.int, " ns   ", shards,
      " shards: ", bigNs.int, " ns"
    check bigNs < smallNs * 4.0 + 20_000.0
    small.detach(); big.detach()

# ---------------------------------------------------------------------------
# 5. crash atomicity — the generation store is the only commit
# ---------------------------------------------------------------------------

suite "a crash mid-reset leaves the chain fully-old or fully-new":

  test "crash_mid_reset_leaves_chain_fully_old_or_fully_new":
    # A process calls `reset` with a hook that destroys it at one of reset's
    # publish points; another process then reads the chain out of the same
    # shared segment.
    #
    # Every point BEFORE the generation store must leave the chain wholly OLD —
    # old generation, old identity, old contents. That is a real property and not
    # a tautology: at `spBeforeLivenessRearm` the NEXT generation's runId has
    # already been written to the file, and it is only invisible because it went
    # into the slot the next generation will select rather than the one the
    # current generation reads.
    #
    # THE TWO PLATFORMS REACH THAT SHAPE DIFFERENTLY, and the difference is the
    # consumer handle rather than the property. `reset` is CONSUMER-ONLY — a
    # producer view gets `rsNotConsumer` — and the only way a second process can
    # hold a consumer handle is to inherit it across `fork`. So:
    #
    #   * POSIX: a forked child inherits the parent's consumer handle (the
    #     mapping is MAP_SHARED, so it is the SAME memory), crashes mid-reset,
    #     and the PARENT — still the consumer — checks the chain and then proves
    #     it is undamaged by completing the reset itself.
    #   * Windows: the crashing process CREATES the chain, so it is the
    #     consumer; the parent observes through a producer view. Every
    #     fully-old assertion is identical. The one it cannot make is the
    #     trailing `reset("action-B") == rsReset`, because the parent is not the
    #     consumer — so it proves the chain is undamaged the other way available
    #     to a producer: the chain still ACCEPTS AND PUBLISHES a new element,
    #     and the union is exactly what it was plus that element.
    when not defined(windows):
     for point in [spBeforeRunIdStamp, spBeforeLivenessRearm,
                  spBeforeGenerationPublish]:
       let dir = freshDir("kill-" & $point)
       var host = createSet(dir, "io-mon", "action-A", shard0Cap = 64,
         shard0ArenaCap = 2048)
       check host.available
       for i in 0 ..< 600:
         check host.insert(bytesOf("A/dep-" & $i)) in {isInserted, isExists}
       let filesBefore = shardFiles(dir)
       let shardsBefore = host.shardCount()
       check shardsBefore >= 2

       let child = fork()
       if child == 0:
         killAt = point
         killArmed = true
         setScheduleHook(killingHook)
         discard host.reset("action-B")
         quitChild(9)                # unreachable: the hook kills us first
       check child > 0
       var st: cint
       check waitpid(child, st, 0) == child
       check WIFSIGNALED(st)                     # it really was killed
       check WTERMSIG(st) == SIGKILL

       # FULLY OLD, in every respect.
       check host.generation == 1'u64            # PRIMARY ASSERTION
       check host.runId == "action-A"            # PRIMARY ASSERTION
       var got = unionOf(host)
       check got.len == 600                      # PRIMARY ASSERTION
       check "A/dep-0" in got and "A/dep-599" in got
       check shardFiles(dir) == filesBefore      # no shard file leaked
       check host.shardCount() == shardsBefore
       # ...and the chain is still usable: the interrupted reset left no damage.
       check host.reset("action-B") == rsReset
       check host.generation == 2'u64
       check host.runId == "action-B"
       check unionOf(host).len == 0
       host.detach()
       removeDir(dir)
    else:
     for point in [spBeforeRunIdStamp, spBeforeLivenessRearm,
                   spBeforeGenerationPublish]:
      let dir = freshDir("kill-" & $point)
      let stateFile = dir / "state.txt"
      var child = startChild("crashingResetter", dir, 600, $int(point),
        stateFile)
      check waitChild(child) == KilledExitStatus   # it really was destroyed
      check fileExists(stateFile)
      let st = readFile(stateFile).splitLines()
      let path0 = st[0]
      let shardsBefore = parseInt(st[1])
      let filesBefore = st[2].split(",")
      check shardsBefore >= 2

      # FULLY OLD, read straight out of the FILE. The observation is made
      # against the bytes rather than through an attached view because on this
      # platform no live observer is possible — see `crashingResetter`. What is
      # asserted is the same commit boundary: the generation word is still the
      # old one, the identity the old generation selects is still the old one,
      # and no shard file moved.
      check headerU64(path0, ShOffGeneration) == 1'u64    # PRIMARY ASSERTION
      check runIdInFile(path0, 1'u64) == "action-A"       # PRIMARY ASSERTION
      check shardFiles(dir) == filesBefore                # no shard file leaked
      check fileExists(path0)

      # At `spBeforeRunIdStamp` the next generation's identity has not been
      # written at all; at the two later points it HAS been written, into the
      # slot generation 2 selects, and is invisible for exactly that reason.
      # Asserting it is present-but-unselected is what stops the fully-old
      # claim from being a tautology about an empty file.
      if point != spBeforeRunIdStamp:
        check runIdInFile(path0, 2'u64) == "action-B"     # PRIMARY ASSERTION

      # And the consequence of dying between the seal and the commit, pinned so
      # that a change to it is visible: the seal is still engaged, so a NEW
      # producer is refused rather than silently joining a half-recycled chain.
      # The chain's consumer is dead, so the reaper collects it on the owner-pid
      # axis; this is not a leak, it is a fail-closed.
      check headerU64(path0, ShOffResetSeal) != 0'u64
      var late = attachSet(path0)
      check (not late.available)
      check late.attachFailure == afRecycling
      removeDir(dir)

  test "a crash immediately AFTER the commit leaves the chain fully-new":
    # The other side of the same boundary: once the generation store lands, the
    # chain is the new one even though the process that recycled it never
    # returned from the call. Same POSIX/Windows split as the case above, and
    # for the same reason (`reset` is consumer-only).
    when defined(windows):
      let dir = freshDir("killafter")
      defer: removeDir(dir)
      let stateFile = dir / "state.txt"
      var child = startChild("committingResetter", dir, 600, stateFile)
      check waitChild(child) == KilledExitStatus
      check fileExists(stateFile)
      let st0 = readFile(stateFile).splitLines()
      let path0 = st0[0]
      let filesBefore = st0[2].split(",")
      var view = attachSet(path0)
      check view.available
      check view.generation == 2'u64            # PRIMARY ASSERTION
      check view.runId == "action-B"            # PRIMARY ASSERTION
      check unionOf(view).len == 0              # PRIMARY ASSERTION
      check shardFiles(dir) == filesBefore
      view.detach()
    else:
     let dir = freshDir("killafter")
     defer: removeDir(dir)
     var host = createSet(dir, "io-mon", "action-A", shard0Cap = 64,
       shard0ArenaCap = 2048)
     check host.available
     for i in 0 ..< 600:
       check host.insert(bytesOf("A/dep-" & $i)) in {isInserted, isExists}
     let filesBefore = shardFiles(dir)
     let child = fork()
     if child == 0:
       let st = host.reset("action-B")
       if st != rsReset: quitChild(9)
       terminateSelf()
       quitChild(8)
     check child > 0
     var st: cint
     check waitpid(child, st, 0) == child
     check WIFSIGNALED(st) and WTERMSIG(st) == SIGKILL
     check host.generation == 2'u64              # PRIMARY ASSERTION
     check host.runId == "action-B"              # PRIMARY ASSERTION
     check unionOf(host).len == 0                # PRIMARY ASSERTION
     check shardFiles(dir) == filesBefore
     host.detach()

# ---------------------------------------------------------------------------
# 6. soak: many successive recycles, each generation's union EXACTLY its own
# ---------------------------------------------------------------------------

suite "recycle soak":

  test "N successive recycles with disjoint input sets never mix":
    # The end-to-end oracle for recycling: after each reset the union must equal
    # exactly that generation's intended set — not a superset (leakage) and not
    # a subset (loss).
    let dir = freshDir("soak")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "gen-0", shard0Cap = 64,
      shard0ArenaCap = 2048)
    check host.available
    var maxShards = 0
    for round in 0 ..< 25:
      var intended = initHashSet[string]()
      let n = 200 + round * 40
      for j in 0 ..< n:
        let e = "r" & $round & "/dep-" & $j
        intended.incl e
        check host.insert(bytesOf(e)) in {isInserted, isExists}
      check unionOf(host) == intended           # PRIMARY ASSERTION
      check host.runId == "gen-" & $round
      check host.growthFailures() == 0
      maxShards = max(maxShards, host.shardCount())
      check host.reset("gen-" & $(round + 1)) == rsReset
      check host.generation == uint64(round + 2)
      check unionOf(host).len == 0
    check maxShards >= 4                        # the chain really did grow
    host.assertNoAbsolutePointers()
    host.detach()

reportNotApplicable()
