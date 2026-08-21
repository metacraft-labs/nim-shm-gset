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

import std/[algorithm, monotimes, os, posix, sets, strutils, times, unittest]
import shm_gset
import shm_gset/transport

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-reset-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result)
  createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc shardFiles(dir: string): seq[string] =
  for _, p in walkDir(dir):
    if ".shard" in extractFilename(p): result.add extractFilename(p)
  result.sort()

proc unionOf[K](s: var ShmGSetT[K]): HashSet[string] =
  result = initHashSet[string]()
  for e in s.items: result.incl strOf(e)

proc waitGone(pid: uint64; timeoutMs = 5000) =
  ## Poll until `pid` is really gone. It is not our child (it was reparented), so
  ## `waitpid` cannot be used.
  var waited = 0
  while waited < timeoutMs:
    if kill(Pid(pid), cint(0)) != 0 and errno == ESRCH: return
    os.sleep(5); waited += 5
  doAssert false, "process " & $pid & " did not exit"

proc parentPidOf(pid: uint64): uint64 =
  ## The pid's CURRENT parent, straight out of `/proc`. Used to prove the
  ## detached descendant really was reparented away from this process rather
  ## than merely being described that way.
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
      var pids: seq[Pid]
      for c in 0 ..< nProc:
        let pid = fork()
        if pid == 0:
          var pr = attachProducer(path0)
          if not pr.available: quitChild(2)
          for j in 0 ..< perProc:
            if pr.emit(bytesOf(tag & "/c" & $c & "/dep-" & $j)) notin
                {emInserted, emExists}:
              pr.detach(); quitChild(3)
          pr.detach(); quitChild(0)
        else:
          doAssert pid > 0
          pids.add pid
      for pid in pids:
        var st: cint
        doAssert waitpid(pid, st, 0) == pid
        doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0

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
    let pid = fork()
    if pid == 0:
      var pr = attachSet(sealPath0)
      let f = pr.attachFailure
      let ok = pr.available
      if ok: pr.detach()
      cExit(if ok: cint(0) elif f == afRecycling: cint(20) else: cint(21))
    var st: cint
    discard waitpid(pid, st, 0)
    sealChildCode = (if WIFEXITED(st): WEXITSTATUS(st) else: -2)

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

    # (b) a DETACHED, session-leading grandchild that outlived its root — the
    # §4.1 shape. The intermediate process exits immediately, so the producer is
    # reparented away from this process entirely and no lifecycle signal this
    # process could observe says it is still there. The registry does.
    var readyPipe, goPipe: array[2, cint]
    check pipe(readyPipe) == 0
    check pipe(goPipe) == 0
    let path0 = host.path0
    let inter = fork()
    if inter == 0:
      discard setsid()                       # leave this process's session
      let gc = fork()
      if gc == 0:
        var pr = attachProducer(path0)
        if not pr.available: quitChild(2)
        if pr.emit(bytesOf("from-detached-descendant")) notin
            {emInserted, emExists}: quitChild(3)
        var me = uint64(getpid())
        if write(readyPipe[1], addr me, 8) != 8: quitChild(4)
        var b: byte
        discard read(goPipe[0], addr b, 1)   # hold the attach open
        pr.detach()
        quitChild(0)
      quitChild(0)                           # root exits; the producer lives on
    check inter > 0
    var st: cint
    check waitpid(inter, st, 0) == inter     # the ROOT is gone...
    var gcPid: uint64
    check read(readyPipe[0], addr gcPid, 8) == 8
    check gcPid != 0
    check parentPidOf(gcPid) != uint64(getpid())   # ...and it was reparented

    check host.attachedProducers == 1
    check host.reset("run-2") == rsBusyProducers   # PRIMARY ASSERTION
    check host.generation == 1'u64
    check host.runId == "run-1"

    # Release it; once it is really gone the same reset succeeds, so the refusal
    # tracks LIVENESS and is not a permanent block.
    var go: byte = 1
    check write(goPipe[1], addr go, 1) == 1
    waitGone(gcPid)
    check host.attachedProducers == 0
    check host.reset("run-2") == rsReset
    check host.generation == 2'u64
    check host.runId == "run-2"
    for fd in [readyPipe[0], readyPipe[1], goPipe[0], goPipe[1]]:
      discard close(fd)

  test "a producer that DIED without detaching does not block recycling forever":
    # The conservative direction must not become a deadlock: a `SIGKILL`ed
    # producer leaves its registry entry behind, and if that were treated as
    # "live" the chain could never be recycled again.
    let dir = freshDir("deadprod")
    defer: removeDir(dir)
    var host = createSet(dir, "io-mon", "run-1", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check host.available
    var readyPipe: array[2, cint]
    check pipe(readyPipe) == 0
    let path0 = host.path0
    let child = fork()
    if child == 0:
      var pr = attachProducer(path0)
      if not pr.available: quitChild(2)
      discard pr.emit(bytesOf("half-written"))
      var me = uint64(getpid())
      discard write(readyPipe[1], addr me, 8)
      while true: os.sleep(60_000)           # never detaches
    check child > 0
    var kid: uint64
    check read(readyPipe[0], addr kid, 8) == 8
    check host.attachedProducers == 1
    check host.reset("run-2") == rsBusyProducers
    check kill(Pid(kid), SIGKILL) == 0
    var st: cint
    discard waitpid(child, st, 0)
    check host.attachedProducers == 0              # entry reclaimed
    check host.reset("run-2") == rsReset           # PRIMARY ASSERTION
    check host.generation == 2'u64
    discard close(readyPipe[0]); discard close(readyPipe[1])
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
    let pid = fork()
    if pid == 0:
      var pr = attachProducer(path0)
      if not pr.available: quitChild(2)
      let st = pr.emit(bytesOf("child-dep"))
      pr.detach()
      quitChild(if st == emInserted: 0 elif st == emConsumerGone: 7 else: 8)
    check pid > 0
    var st: cint
    check waitpid(pid, st, 0) == pid
    check WIFEXITED(st)
    check WEXITSTATUS(st) == 0                       # PRIMARY ASSERTION
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

var killAt: SchedulePoint
var killArmed = false

proc killingHook(point: SchedulePoint) {.gcsafe, raises: [].} =
  if killArmed and point == killAt:
    discard kill(getpid(), SIGKILL)

suite "a crash mid-reset leaves the chain fully-old or fully-new":

  test "crash_mid_reset_leaves_chain_fully_old_or_fully_new":
    # A forked child inherits the consumer handle (the mapping is MAP_SHARED, so
    # it is the SAME memory) and calls `reset` with a hook that `SIGKILL`s it at
    # one of reset's publish points. The parent then reads the chain out of the
    # same shared segment.
    #
    # Every point BEFORE the generation store must leave the chain wholly OLD —
    # old generation, old identity, old contents. That is a real property and not
    # a tautology: at `spBeforeLivenessRearm` the NEXT generation's runId has
    # already been written to the file, and it is only invisible because it went
    # into the slot the next generation will select rather than the one the
    # current generation reads.
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

  test "a crash immediately AFTER the commit leaves the chain fully-new":
    # The other side of the same boundary: once the generation store lands, the
    # chain is the new one even though the process that recycled it never
    # returned from the call.
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
      discard kill(getpid(), SIGKILL)
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
