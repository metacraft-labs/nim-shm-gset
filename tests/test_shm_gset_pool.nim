## HOST-SIDE RECYCLING POOL suite (HM-3) — `src/shm_gset/pool.nim`.
##
## NOTHING HERE IS MOCKED. Every case runs against real shard files in a real
## directory, created by the real `newSetPool` → `acquire` → `startHost` /
## `reset` path, filled by real `attachProducer` producers over real shared
## memory (in-process producers where the property is about the CHAIN, real
## `fork`ed processes where the property is about a process boundary, real OS
## threads where the property is about concurrency), and torn down by real
## `unlink`. No mock is used and none was needed, so this file carries no mock
## justification under the workspace policy.
##
## Built with `-d:shmGSetScheduleHooks`, because one property is not reachable
## otherwise: the pool's `rsGenerationExhausted` ⇒ RETIRE branch needs the
## generation counter driven to its last value, and the seam that does that is
## compile-time gated so it cannot ship. Without the flag the file does not
## compile, so it cannot silently degrade into a weaker run.
##
## THE FOUR MILESTONE PROPERTIES, and the failure each guards:
##
##   1. `pool_stops_growing_after_warmup` — the entire point of recycling, and
##      it must be MEASURED. Twelve actions of similar input size through one
##      pool must link the shards ONCE; the same twelve actions without the pool
##      re-grow the whole chain every time. If this breaks, the pool is a
##      no-op wrapper around `createSet` and the campaign's latency argument is
##      gone.
##   2. `pool_never_hands_out_an_unreset_chain` — the structural guarantee. If
##      this breaks, one action is handed another action's evidence: a wrong
##      dependency set, the cardinal sin.
##   3. `recycle_soak` — many successive recycles, disjoint input sets, exact
##      union per generation. Lives in `test_shm_gset_soak.nim` (it is the soak
##      harness extended, per the milestone) rather than here.
##   4. `pool_under_concurrency_never_shares_a_chain` — N in-flight actions.
##      If this breaks, two actions write into one segment and BOTH dependency
##      sets are wrong.
##
## Plus the consumer-identity semantics chosen for the reaper hazard HM-2
## recorded (`pooled_chain_owner_is_the_pool_process`,
## `a_fork_child_cannot_touch_the_parents_pooled_chain` and
## `a_fork_child_cannot_destroy_the_parents_pool` — one per guarded entry point:
## the first two cover `acquire` / `release` / `close`, the last covers
## `destroySetPool`, which was untested and therefore shipped unguarded for a
## round), and the three `ResetStatus` refusal policies the campaign specified.
##
## And three properties that were ASSERTED IN PROSE before they were tested —
## each added after a mutation of the shipped code reddened nothing:
##
##   - `release_marks_the_consumer_gone_for_a_late_producer` — deleting
##     `markConsumerGone` from `release` used to leave the whole suite green,
##     while the README and the milestone both claimed the behaviour.
##   - `a dropped lease survives close and is swept by destroySetPool` — the
##     honest shape of "close leaves nothing behind", including what it does
##     NOT clean up and where that is cleaned up instead.
##   - `destroySetPool_frees_the_pools_own_buffers` — the pool's own heap, not
##     the segment's: `allocShared0` memory has no destructor, so a seq whose
##     payload is merely truncated is orphaned (valgrind: 136 bytes definitely
##     lost, per pool).

import std/[locks, os, osproc, posix, sets, strutils, unittest]
import shm_gset
import shm_gset/transport
import shm_gset/pool

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-pool-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result)
  createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc shardFileCount(dir: string): int =
  for _, p in walkDir(dir):
    if ".shard" in extractFilename(p): inc result

proc emitSet(path0: string; tag: string; n: int): bool =
  ## Fill a leased chain the way an action does: attach a REAL producer to the
  ## well-known path, emit, detach. Detaching matters — an attached producer is
  ## exactly what makes the next `reset` refuse.
  var pr = attachProducer(path0)
  if not pr.available: return false
  for j in 0 ..< n:
    if pr.emit(bytesOf(tag & "/path/to/file-" & $j & ".h")) notin
        {emInserted, emExists}:
      pr.detach(); return false
  pr.detach()
  true

proc expectedSet(tag: string; n: int): HashSet[string] =
  result = initHashSet[string]()
  for j in 0 ..< n: result.incl(tag & "/path/to/file-" & $j & ".h")

proc unionOfLease(l: var SetLease): HashSet[string] =
  result = initHashSet[string]()
  for e in l.items: result.incl strOf(e)

proc headerU64(path0: string; off: int): uint64 =
  ## Read one fixed-header word straight out of the shard FILE. Used to observe
  ## `ShOffConsumerPid` — which nothing in the library ever reads back — so the
  ## consumer-identity semantics are asserted against the bytes rather than
  ## against the code that writes them.
  let f = open(path0, fmRead)
  defer: f.close()
  f.setFilePos(off)
  var buf: array[8, byte]
  doAssert f.readBytes(buf, 0, 8) == 8
  copyMem(addr result, addr buf[0], 8)

# ---------------------------------------------------------------------------
# 1. the measured point of the milestone: growth stops after warmup
# ---------------------------------------------------------------------------

suite "recycling actually recycles":

  test "pool_stops_growing_after_warmup":
    # TWELVE actions of similar input size, not two.
    #
    # WHY TWELVE. The one failure mode this property has is an arena bump
    # pointer that does not REBASE across generations (HM-2). MEASURED under
    # THIS test's parameters — shard0Cap 64, arena 2048, 1500 elements an action
    # — by deleting the rebase from `reserveArena` in a scratch copy of `src/`
    # and running exactly the loop below:
    #
    #   shipped:      4 4 4 4 4 4 4 4 4 4 4 4
    #   no rebase:    4 4 5 5 5 5 5 5 5 5 5 6
    #
    # So the growth is NOT periodic: the extra shard first appears on the THIRD
    # fill and the next one only NINE fills later, because what decides when the
    # chain links again is how much of the newest shard's arena a generation
    # happens to consume. (HM-2's "one shard every second fill" was measured on
    # a differently-parameterised chain and does not hold here; it is not a
    # constant of the defect.)
    #
    # Two things follow. A two-round test passes whether or not the property it
    # names holds, which is exactly what happened in HM-2. And eleven
    # post-warmup fills is the MARGIN this buys: for the defect above, rounds
    # 2..11 each redden `perRound[r] == warm` — ten independent failures rather
    # than one — and a variant with more arena headroom, whose first extra link
    # lands later, is still caught anywhere up to the eleventh fill.
    const
      rounds = 12
      perAction = 1500
    let pooledDir = freshDir("warmup-pooled")
    let plainDir = freshDir("warmup-plain")
    defer:
      removeDir(pooledDir); removeDir(plainDir)

    var p = newSetPool(pooledDir, "io-mon", shard0Cap = 64,
      shard0ArenaCap = 2048, maxIdle = 4)
    var perRound: seq[int]
    var filesPerRound: seq[int]
    var anchors = initHashSet[string]()
    for r in 0 ..< rounds:
      var l = p.acquire("action-" & $r)
      check l.available
      anchors.incl l.path0
      check emitSet(l.path0, "r" & $r, perAction)
      check l.snapshot().len == perAction        # the action really ran
      check l.growthFailures() == 0'u64
      perRound.add l.shardCount()
      filesPerRound.add shardFileCount(pooledDir)
      l.release()

    let warm = perRound[0]
    check warm >= 3                              # the chain really did grow
    # PRIMARY ASSERTION: after the warmup action, no action links a shard.
    for r in 1 ..< rounds:
      check perRound[r] == warm
      check filesPerRound[r] == filesPerRound[0]
    check anchors.len == 1                       # ...and it was ONE chain
    let st = p.stats
    check st.acquires == rounds
    check st.createdChains == 1                  # PRIMARY ASSERTION
    check st.recycledAcquires == rounds - 1
    let pooledFiles = shardFileCount(pooledDir)
    check pooledFiles == warm

    # The BASELINE the saving is measured against: the same twelve actions with
    # no pool re-grow the whole chain every time. Without this the assertions
    # above could be satisfied by a workload that never grows at all.
    for r in 0 ..< rounds:
      var h = startHost(plainDir, "action-" & $r, "io-mon", shard0Cap = 64,
        shard0ArenaCap = 2048)
      check h.available
      check emitSet(h.path0, "r" & $r, perAction)
      check h.snapshot().len == perAction
      check h.shardCount() == warm
      h.finish()
    let plainFiles = shardFileCount(plainDir)
    check plainFiles == rounds * warm            # PRIMARY ASSERTION (baseline)
    echo "  [recycling] shard files after ", rounds, " actions: pooled ",
      pooledFiles, "  unpooled ", plainFiles, "  (chain is ", warm, " shards)"
    check p.close() == 0
    check shardFileCount(pooledDir) == 0         # the pool leaves nothing behind

# ---------------------------------------------------------------------------
# 2. the structural guarantee
# ---------------------------------------------------------------------------

suite "the pool owns reset":

  test "pool_never_hands_out_an_unreset_chain":
    let dir = freshDir("unreset")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048,
      maxIdle = 2)

    # --- STRUCTURAL half: the shapes, not the values. -----------------------
    # A lease cannot be forged (private fields), cannot be recycled, ended or
    # torn down by its holder, and cannot be duplicated into a second lease over
    # the same chain. These are compile-time facts; if any of them started to
    # compile the guarantee would have become a convention.
    var probe = p.acquire("probe")
    check probe.available
    check (not compiles(SetLease(live: true)))          # no public constructor
    check (not compiles(probe.reset("x")))              # reset is not reachable
    check (not compiles(probe.finish()))
    check (not compiles(probe.markConsumerGone()))
    check (not compiles(p.idle))                        # the idle list is private
    probe.release()

    # A lease also cannot be DUPLICATED — a copy released twice would put one
    # chain into the idle list twice, and the next two acquires would hand the
    # same shards to two concurrent actions. `compiles()` cannot see that: the
    # `=copy` hook is injected after the sem phase it reports on, so it answers
    # TRUE while `nim c` on the same code fails. The property is therefore
    # compiled for real, both ways, with a positive control so a fixture that
    # broke for an unrelated reason cannot masquerade as a pass.
    let srcDir = currentSourcePath().parentDir.parentDir / "src"
    let probeSrc = currentSourcePath().parentDir / "helpers" / "lease_copy_probe.nim"
    check fileExists(probeSrc)
    proc buildProbe(defines: string): tuple[output: string, exitCode: int] =
      execCmdEx("nim c --hints:off --threads:on --warning:BareExcept:off" &
        " --path:" & quoteShell(srcDir) & " " & defines &
        " -o:" & quoteShell(getTempDir() / "shmgset-lease-copy-probe-bin") &
        " " & quoteShell(probeSrc))
    let control = buildProbe("-d:leaseProbeMove")
    check control.exitCode == 0                             # POSITIVE CONTROL
    let copyAttempt = buildProbe("")
    check copyAttempt.exitCode != 0                         # PRIMARY ASSERTION
    check "'=copy' is not available for type <SetLease>" in copyAttempt.output
                                                        # PRIMARY ASSERTION:
                                                        # and it failed for THAT
                                                        # reason, not another

    # --- OBSERVABLE half: twenty rounds through one chain. ------------------
    const rounds = 20
    var lastGen = 0'u64
    var lastSet = initHashSet[string]()
    var anchor = ""
    for r in 0 ..< rounds:
      var l = p.acquire("gen-" & $r)
      check l.available
      if anchor.len == 0: anchor = l.path0
      check l.path0 == anchor                    # the SAME chain every round
      check l.snapshot().len == 0                # PRIMARY ASSERTION: empty
      check l.claimedSlots() == 0'u64            # PRIMARY ASSERTION: no residue
      check l.runId == "gen-" & $r               # PRIMARY ASSERTION: re-stamped
      check l.generation > lastGen               # PRIMARY ASSERTION: reset ran
      # ...and specifically NOT the previous round's contents.
      let seen = unionOfLease(l)
      check seen.len == 0
      for e in lastSet:
        check e notin seen
      lastGen = l.generation
      check emitSet(l.path0, "r" & $r, 400)
      lastSet = expectedSet("r" & $r, 400)
      check unionOfLease(l) == lastSet
      l.release()

    # An INDEPENDENT reader, attaching from scratch by path, sees the same
    # thing: the last round's set and nothing older.
    var reader = attachSet(anchor)
    check reader.available
    var readerSaw = initHashSet[string]()
    for e in reader.items: readerSaw.incl strOf(e)
    check readerSaw == lastSet
    check reader.runId == "gen-" & $(rounds - 1)
    reader.detach()
    check p.close() == 0

# ---------------------------------------------------------------------------
# 3. concurrency — N in-flight actions never share a chain
# ---------------------------------------------------------------------------

type WorkerArg = object
  p: SetPool
  id: int
  rounds: int
  perRound: int

var gGuard: Lock
var gInUse: HashSet[string]
var gViolations: int
var gMaxConcurrent: int
var gOracleFailures: int
var gAcquireFailures: int
var gChains: HashSet[string]

proc worker(a: WorkerArg) {.thread.} =
  {.cast(gcsafe).}:
    for r in 0 ..< a.rounds:
      let tag = "w" & $a.id & "r" & $r
      var l = a.p.acquire(tag)
      if not l.available:
        withLock gGuard: inc gAcquireFailures
        continue
      let anchor = l.path0
      withLock gGuard:
        if anchor in gInUse: inc gViolations   # TWO leases over ONE chain
        gInUse.incl anchor
        gChains.incl anchor
        gMaxConcurrent = max(gMaxConcurrent, gInUse.len)
      # Do a real action's worth of work while holding it, so the windows
      # genuinely overlap rather than serialising on the pool's lock.
      var ok = emitSet(anchor, tag, a.perRound)
      # ORACLE: this action's union must be EXACTLY this action's set — not a
      # superset (another thread's chain, or the previous action's residue) and
      # not a subset.
      if ok:
        var got = initHashSet[string]()
        for e in l.items: got.incl strOf(e)
        if got != expectedSet(tag, a.perRound): ok = false
        if l.runId != tag: ok = false
      withLock gGuard:
        gInUse.excl anchor
        if not ok: inc gOracleFailures
      l.release()

suite "the pool under concurrency":

  test "pool_under_concurrency_never_shares_a_chain":
    # This case found a defect no single-threaded test could. The pool was
    # first written as a `ref object`; it passed every functional assertion here
    # and then SIGSEGV'd inside `arc.nim`'s `isObjDisplayCheck`, in a LATER test
    # than this one — INTERMITTENTLY, in a minority of whole-file runs, at a
    # sampled rate that wandered between roughly one run in six and one in eight
    # across the samples taken. ORC's reference counts are atomic only under
    # `-d:gcAtomicArc` (see the `when` guard in `system/arc.nim`), so handing a
    # `ref` to six threads races the counter and frees a live object a long way
    # from the code that did it.
    #
    # That spread is the point, and it is not a specification: no feasible
    # number of clean runs settles an event at that frequency, so the fix was
    # settled with TSAN instead, over exactly this test:
    #
    #   ref  SetPoolObj  ->  data races on the POOL'S OWN refcount —
    #                        `nimIncRef` / `nimDecRef` reached from `acquire` /
    #                        `release` in two different worker threads
    #   ptr  SetPoolObj  ->  NONE, test green
    #
    # The DIRECTION is the result; the count is not. TSAN reports races per
    # observed schedule, so how many it prints on the `ref` build varies run to
    # run and must not be written down as a number the build is expected to
    # reproduce. Nonzero versus zero is what is load-bearing.
    #
    # `SetPool` is therefore a raw `ptr` and every GC'd field behind it is
    # touched only under the pool's lock. The TSAN run is wired as
    # `just test-sanitizers` so it stays a guard rather than an anecdote.
    let dir = freshDir("threads")
    defer: removeDir(dir)
    initLock(gGuard)
    gInUse = initHashSet[string]()
    gChains = initHashSet[string]()
    gViolations = 0
    gMaxConcurrent = 0
    gOracleFailures = 0
    gAcquireFailures = 0
    const
      nThreads = 6
      rounds = 25
      perRound = 300
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048,
      maxIdle = nThreads)
    var ths: array[nThreads, Thread[WorkerArg]]
    for i in 0 ..< nThreads:
      createThread(ths[i], worker,
        WorkerArg(p: p, id: i, rounds: rounds, perRound: perRound))
    joinThreads(ths)
    check gViolations == 0                      # PRIMARY ASSERTION
    check gOracleFailures == 0                  # PRIMARY ASSERTION
    check gAcquireFailures == 0
    check gMaxConcurrent >= 2                   # the windows really did overlap
    check p.stats.acquires == nThreads * rounds
    check p.stats.releases == nThreads * rounds
    check p.leasedChains == 0
    # The pool created at most one chain per concurrent action and reused them:
    # far fewer chains than the 150 actions that ran.
    check gChains.len <= nThreads
    check p.stats.createdChains == gChains.len
    echo "  [pool concurrency] ", nThreads * rounds, " actions over ",
      gChains.len, " chains, max ", gMaxConcurrent, " in flight"
    check p.close() == 0
    check shardFileCount(dir) == 0
    destroySetPool(p)                           # releases the shared object
    check p == nil
    deinitLock(gGuard)

# ---------------------------------------------------------------------------
# 4. who owns a pooled chain — the reaper hazard, decided
# ---------------------------------------------------------------------------

suite "a pooled chain is owned by the POOL's process":

  test "pooled_chain_owner_is_the_pool_process":
    # HM-2 flagged that `reset` re-points `ShOffConsumerPid` at the CALLING
    # process and warned that this could hand the reaper an owner pid that
    # exits first. Two facts settle it, and both are asserted here rather than
    # reasoned about:
    #
    #   (a) the reaper does not read that field at all — its owner pid comes
    #       from the shard file's NAME, which `reset` never touches. So a chain
    #       recycled twenty times still carries the pid it was CREATED with,
    #       and the reaper's verdict follows the pool's process;
    #   (b) the pool keeps the two identities from ever diverging anyway, by
    #       creating every chain it manages and refusing to operate from any
    #       other process (the next test).
    let dir = freshDir("owner")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048)
    var anchor = ""
    for r in 0 ..< 20:
      var l = p.acquire("run-" & $r)
      check l.available
      if anchor.len == 0: anchor = l.path0
      check emitSet(l.path0, "r" & $r, 200)
      l.release()

    # (a) the NAME still says this process, after twenty recycles.
    let stem = extractFilename(anchor)
    let namePid = stem[0 ..< stem.len - ".shard0".len].rsplit('.', 2)[2]
    check namePid == $getpid()                   # PRIMARY ASSERTION
    # ...and the header field agrees, because the resetter IS the owner.
    check headerU64(anchor, ShOffConsumerPid) == uint64(getpid())
    # ...so the reaper leaves the chain alone however often it was recycled.
    check reapStaleSegmentsDetailed(dir, "io-mon").len == 0   # PRIMARY ASSERTION
    check shardFileCount(dir) > 0

    # And the other half of the same rule: a chain whose pool's process is DEAD
    # is collected, whatever its generation. A child creates its own pool, runs
    # actions, recycles, and exits WITHOUT closing.
    let dir2 = freshDir("owner-dead")
    defer: removeDir(dir2)
    let child = fork()
    if child == 0:
      var cp = newSetPool(dir2, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048)
      for r in 0 ..< 3:
        var cl = cp.acquire("child-" & $r)
        if not cl.available: quitChild(2)
        if not emitSet(cl.path0, "c" & $r, 200): quitChild(3)
        cl.release()
      quitChild(0)                               # no close: files are left
    check child > 0
    var st: cint
    check waitpid(child, st, 0) == child
    check WIFEXITED(st) and WEXITSTATUS(st) == 0
    check shardFileCount(dir2) > 0
    let reaped = reapStaleSegmentsDetailed(dir2, "io-mon")
    check reaped.len == 1                        # PRIMARY ASSERTION
    check reaped[0].runIdFromHeader
    check reaped[0].runId == "child-2"           # the LAST identity it carried
    check shardFileCount(dir2) == 0
    check p.close() == 0

  test "a_fork_child_cannot_touch_the_parents_pooled_chain":
    # The pool is not fork-inheritable, and that is a correctness rule rather
    # than hygiene. The mapping is MAP_SHARED, so a child that "released" an
    # inherited lease would `markConsumerGone` on a chain the PARENT is still
    # serving an action with — and every producer of that action would begin
    # fast-failing with `emConsumerGone`: unmonitored, and silently. A child
    # that "acquired" would reset the parent's live chain out from under it.
    let dir = freshDir("forkpool")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048)
    var l = p.acquire("parent-run")
    check l.available
    check emitSet(l.path0, "before", 100)
    let genBefore = l.generation
    let path0 = l.path0

    let child = fork()
    if child == 0:
      # Exactly what a forked action host would do with an inherited pool.
      var inherited = p.acquire("child-run")
      let acquireRefused = (not inherited.available) and
        inherited.refusal == prForeignProcess
      l.release()                                 # must be a no-op here
      let closeRefused = p.close() < 0
      quitChild(if acquireRefused and closeRefused: cint(0) else: cint(6))
    check child > 0
    var st: cint
    check waitpid(child, st, 0) == child
    check WIFEXITED(st)
    check WEXITSTATUS(st) == 0                    # PRIMARY ASSERTION (refusals)

    # The parent's action is untouched in every respect that matters.
    check l.available
    check l.generation == genBefore               # PRIMARY ASSERTION
    check l.runId == "parent-run"
    check headerU64(path0, ShOffConsumerPid) == uint64(getpid())
    var pr = attachProducer(path0)
    check pr.available
    check pr.emit(bytesOf("after/still-monitored")) == emInserted
                                                  # PRIMARY ASSERTION: the
                                                  # consumer is still LIVE
    pr.detach()
    check unionOfLease(l).len == 101
    l.release()
    check p.close() == 0

  test "a_fork_child_cannot_destroy_the_parents_pool":
    # `destroySetPool` is the FOURTH ownership-guarded entry point, and for one
    # round it was the only UNGUARDED one — which made it the most destructive
    # call in the module, because it is the only one that unlinks
    # UNCONDITIONALLY. `close` is guarded and `release` is guarded, so nothing
    # else a child can call touches a file. Measured on the unguarded build,
    # with the parent MID-ACTION and the child calling `destroySetPool` on the
    # inherited pool:
    #
    #   after child destroySetPool: files=0, parent anchor exists=false
    #   parent producer attach available=false
    #
    # That is strictly WORSE than the fault the ownership rule exists to
    # prevent. A child's stray `markConsumerGone` leaves the parent's producers
    # fast-failing with `emConsumerGone` — wrong, but VISIBLE. An unlinked
    # anchor leaves them unable to `attachProducer` at all: the parent's action
    # is unmonitored and nothing anywhere says so.
    #
    # The sibling test above covers `acquire` / `release` / `close` from a
    # child. This one exists because `destroySetPool` in a fork child was
    # COMPLETELY UNTESTED, which is how the regression got in.
    let dir = freshDir("forkdestroy")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048)
    var l = p.acquire("parent-run")             # the parent is MID-ACTION: the
    check l.available                           # lease is outstanding, so the
    let path0 = l.path0                         # chain is in `created` and the
    check emitSet(path0, "before", 100)         # unguarded sweep would take it
    let filesBefore = shardFileCount(dir)
    check filesBefore > 0

    let child = fork()
    if child == 0:
      destroySetPool(p)
      # THE REFUSAL CHANNEL. A destroy in the OWNING process nils `p`, so `p`
      # still being non-nil after the call is exactly "this process was
      # refused" — the fourth distinct channel, after `acquire`'s
      # `prForeignProcess`, `close`'s `-1`, and `release`'s silence.
      quitChild(if p == nil: cint(7) else: cint(0))
    check child > 0
    var st: cint
    check waitpid(child, st, 0) == child
    check WIFEXITED(st)
    check WEXITSTATUS(st) == 0                  # PRIMARY ASSERTION: `p` stayed
                                                # non-nil in the child

    # The parent's live action survives, in the way that actually matters.
    check fileExists(path0)                     # PRIMARY ASSERTION
    check shardFileCount(dir) == filesBefore    # PRIMARY ASSERTION: no sweep
    var pr = attachProducer(path0)
    check pr.available                          # PRIMARY ASSERTION: the parent's
                                                # action is still MONITORABLE at
                                                # all — this is the one the
                                                # unguarded build silently loses
    check pr.emit(bytesOf("after/still-monitored")) == emInserted
    pr.detach()
    check l.available
    check l.runId == "parent-run"
    check unionOfLease(l).len == 101
    l.release()

    # CONTROL, so this cannot be satisfied by a `destroySetPool` that does
    # nothing for ANYONE: in the OWNING process it must still nil `p` and still
    # take the files with it.
    destroySetPool(p)
    check p == nil                              # PRIMARY ASSERTION (control)
    check shardFileCount(dir) == 0              # PRIMARY ASSERTION (control)

# ---------------------------------------------------------------------------
# 5. the refusal policies — retry vs retire, per `ResetStatus`
# ---------------------------------------------------------------------------

suite "the pool's policy for each reset refusal":

  test "rsBusyProducers is RETRIED, then the chain is retired":
    # Transient by nature: the refusal clears when those processes exit. But it
    # is not GUARANTEED to clear — a detached descendant that outlives its root
    # is the §4.1 shape — so an unbounded retry would wedge the pool on one
    # chain forever. Budgeted retry, then retire.
    let dir = freshDir("busy")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048,
      maxIdle = 4, busyRetryBudget = 3)
    var l = p.acquire("run-0")
    check l.available
    let stuckAnchor = l.path0
    # A producer that attaches and NEVER detaches: the chain can never be reset.
    var stuck = attachProducer(stuckAnchor)
    check stuck.available
    check stuck.emit(bytesOf("held-open")) == emInserted
    l.release()
    check p.idleChains == 1

    # Acquire 1 and 2 REFUSE the busy chain and create a new one instead of
    # blocking; the busy chain stays idle with its refusal count carried over.
    for attempt in 1 .. 2:
      var l2 = p.acquire("retry-" & $attempt)
      check l2.available
      check l2.path0 != stuckAnchor              # PRIMARY ASSERTION: not shared
      check p.stats.busyRefusals == attempt      # PRIMARY ASSERTION: retried
      check p.stats.retired[rrBusyBudgetExhausted] == 0
      check fileExists(stuckAnchor)              # ...and not yet given up on
      l2.release()

    # The third consecutive refusal exhausts the budget: retire, and unlink.
    var l4 = p.acquire("retry-3")
    check l4.available
    check p.stats.busyRefusals == 3
    check p.stats.retired[rrBusyBudgetExhausted] == 1   # PRIMARY ASSERTION
    check (not fileExists(stuckAnchor))                 # PRIMARY ASSERTION
    check l4.path0 != stuckAnchor
    l4.release()
    stuck.detach()
    check p.close() == 0
    check shardFileCount(dir) == 0

  test "rsProducersUntracked RETIRES the chain rather than retrying it":
    # A producer that attached while the registry was full leaves a count the
    # chain can never attribute to a pid. If it dies without detaching the count
    # never falls, so the chain would stop recycling FOREVER while looking
    # merely busy. The pool retires it instead — one chain's capacity against a
    # chain that quietly never recycles again.
    let dir = freshDir("untracked")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
      maxIdle = 4)
    var l = p.acquire("run-0")
    check l.available
    let anchor = l.path0
    var held: seq[ShmGSet]
    for i in 0 ..< MaxRegisteredProducers:
      var pr = attachSet(anchor)
      check pr.available
      held.add pr
    var overflowed = attachSet(anchor)           # the registry is full now
    check overflowed.available                   # never fail a producer
    check l.untrackedProducers == 1
    for pr in held.mitems: pr.detach()           # only the UNTRACKED one is left
    check l.attachedProducers == 1
    check l.untrackedProducers == 1
    l.release()

    var l2 = p.acquire("run-1")
    check l2.available
    check l2.path0 != anchor                              # PRIMARY ASSERTION
    check p.stats.retired[rrProducersUntracked] == 1      # PRIMARY ASSERTION
    check p.stats.busyRefusals == 0                       # NOT retried
    check (not fileExists(anchor))                        # PRIMARY ASSERTION
    l2.release()
    overflowed.detach()
    check p.close() == 0
    check shardFileCount(dir) == 0

  test "rsGenerationExhausted RETIRES the chain rather than retrying it":
    # 32 bits of generation live in every slot entry, so a chain can be recycled
    # 2^32-1 times and then not again. `reset` refuses rather than wrapping; the
    # pool must create a new chain rather than looping on the refusal. Driven
    # with the compile-time-gated test seam instead of 4.29e9 recycles.
    let dir = freshDir("exhausted")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
      maxIdle = 4)
    var l = p.acquire("run-0")
    check l.available
    let anchor = l.path0
    l.release()
    check p.forceIdleGenerationsForTest(MaxGeneration) == 1

    var l2 = p.acquire("run-1")
    check l2.available
    check l2.path0 != anchor                              # PRIMARY ASSERTION
    check p.stats.retired[rrGenerationExhausted] == 1     # PRIMARY ASSERTION
    check p.stats.createdChains == 2
    check (not fileExists(anchor))                        # PRIMARY ASSERTION
    l2.release()
    check p.close() == 0
    check shardFileCount(dir) == 0

  test "a bad runId refuses the ACQUIRE and destroys no chain":
    # The one refusal that is a CALLER fault rather than a chain fault. A naive
    # "anything but rsReset ⇒ retire" would throw away a perfectly good chain
    # for a bad argument, so it is pre-validated and no chain is touched.
    let dir = freshDir("badrunid")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024)
    var l = p.acquire("ok")
    check l.available
    let anchor = l.path0
    l.release()
    var bad = p.acquire(repeat('r', RunIdMaxBytes + 1))
    check (not bad.available)                             # PRIMARY ASSERTION
    check bad.refusal == prInvalidRunId                   # PRIMARY ASSERTION
    check p.idleChains == 1                               # nothing was taken
    check fileExists(anchor)                              # PRIMARY ASSERTION
    check p.stats.acquires == 1
    var good = p.acquire(repeat('r', RunIdMaxBytes))
    check good.available
    check good.path0 == anchor                            # the same chain
    check good.runId == repeat('r', RunIdMaxBytes)
    good.release()
    check p.close() == 0
    check shardFileCount(dir) == 0

  test "an idle list at capacity retires rather than growing without bound":
    # The warm-chain count is the memory recycling costs, so it is bounded.
    let dir = freshDir("maxidle")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
      maxIdle = 2)
    var a = p.acquire("a")
    var b = p.acquire("b")
    var c = p.acquire("c")
    check a.available and b.available and c.available
    check p.leasedChains == 3
    check shardFileCount(dir) == 3
    a.release(); b.release(); c.release()
    check p.idleChains == 2                               # PRIMARY ASSERTION
    check p.stats.retired[rrIdleOverflow] == 1            # PRIMARY ASSERTION
    check shardFileCount(dir) == 2                        # PRIMARY ASSERTION
    check p.close() == 0
    check shardFileCount(dir) == 0

  test "close reports outstanding leases and leaves no file behind":
    let dir = freshDir("close")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024)
    var a = p.acquire("a")
    check a.available
    check p.close() == 1                        # PRIMARY ASSERTION: outstanding
    check fileExists(a.path0)                   # ...so nothing was unlinked
    a.release()                                 # a closed pool retires on return
    check p.stats.retired[rrPoolClosed] == 1
    check shardFileCount(dir) == 0              # PRIMARY ASSERTION
    var after = p.acquire("b")
    check (not after.available)
    check after.refusal == prClosed

# ---------------------------------------------------------------------------
# 6. release ENDS THE ACTION for every producer of it
# ---------------------------------------------------------------------------

suite "release ends the action for its producers":

  test "release_marks_the_consumer_gone_for_a_late_producer":
    # THE PROPERTY THE README AND THE MILESTONE BOTH ASSERT, and which nothing
    # tested until now: `release` marks the consumer GONE, so a producer of the
    # FINISHED action that emits afterwards fast-fails with `emConsumerGone`
    # instead of writing into a chain the next action is about to be handed.
    # It was asserted in prose and reachable by inspection; deleting
    # `markConsumerGone` from `release` left the whole suite green — all 97
    # tests of it AS IT THEN STOOD; the suite is 101 now, and this case is one
    # of the four added since — so the safety net was untested. This is that
    # test. Re-run in the final verification round against the current tree:
    # the same deletion now reddens both `== emConsumerGone` checks below.
    #
    # It also underwrites the claim `pool.nim`'s header makes about RETIREMENT:
    # unlinking a chain that still has a producer attached is safe *because*
    # release already marked the consumer gone, so no condemned chain can accept
    # an insert — and therefore cannot grow a new shard file behind the unlink.
    # Both halves are asserted below.
    let dir = freshDir("consumergone")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048,
      maxIdle = 4)
    var l = p.acquire("action-0")
    check l.available
    let anchor = l.path0

    # A REAL producer of this action that is STILL ATTACHED when the action
    # ends — the §4.1 shape: a descendant that outlives the tree its root
    # belonged to and keeps writing.
    var late = attachProducer(anchor)
    check late.available
    check late.emit(bytesOf("during/the/action.h")) == emInserted  # CONTROL:
                                                # it really could write before
    check l.snapshot().len == 1
    let filesDuringAction = shardFileCount(dir)

    l.release()                                 # THE ACTION ENDS HERE

    check late.emit(bytesOf("after/the/action.h")) == emConsumerGone
                                                # PRIMARY ASSERTION
    check late.emit(bytesOf("during/the/action.h")) == emConsumerGone
                                                # PRIMARY ASSERTION: not even a
                                                # re-emit of an element already
                                                # present gets through
    check shardFileCount(dir) == filesDuringAction
                                                # PRIMARY ASSERTION: a condemned
                                                # chain cannot grow a file either
    late.detach()

    # ...and the next action, which recycles this very chain, sees NONE of it.
    var l2 = p.acquire("action-1")
    check l2.available
    check l2.path0 == anchor                    # the same chain, recycled
    check l2.snapshot().len == 0                # PRIMARY ASSERTION
    var seen = unionOfLease(l2)
    check "after/the/action.h" notin seen
    check "during/the/action.h" notin seen
    l2.release()
    check p.close() == 0
    check shardFileCount(dir) == 0

# ---------------------------------------------------------------------------
# 7. shutdown leaves nothing behind — on disk OR in the heap
# ---------------------------------------------------------------------------

suite "the pool's own shutdown":

  test "a dropped lease survives close and is swept by destroySetPool":
    # A lease that is DROPPED rather than released is the one case the pool
    # cannot recover from on its own: nothing decrements `leasedNow`, so the
    # chain stays outstanding forever. This test pins the ACTUAL guarantee,
    # both halves of it, because the weaker half used to be documented as the
    # stronger one:
    #
    #   `close`           — REPORTS the outstanding lease (nonzero) and unlinks
    #                       nothing of it. It must not: from the pool's side a
    #                       lease an action is still writing to and a lease that
    #                       will never come back are the same state.
    #   `destroySetPool`  — the host's statement that nothing will touch the
    #                       pool again, so an outstanding chain is abandoned by
    #                       definition. THIS is where the files go.
    let dir = freshDir("dropped")
    defer: removeDir(dir)
    var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
      maxIdle = 4)
    var kept = p.acquire("kept")
    check kept.available
    let keptPath = kept.path0
    var droppedPath = ""
    block:
      var dropped = p.acquire("dropped")
      check dropped.available
      droppedPath = dropped.path0
      check droppedPath != keptPath             # two chains, both in flight
      check emitSet(droppedPath, "d", 50)
      # `dropped` leaves scope here WITHOUT `release`. `SetLease` has no
      # destructor, so nothing hands the chain back: this IS "dropped rather
      # than released", produced rather than simulated.
    kept.release()
    check p.leasedChains == 1                   # the dropped one, forever
    check fileExists(keptPath)
    check fileExists(droppedPath)
    # The dropped chain was filled hard enough to LINK a second shard, so the
    # sweep below has to follow the chain rather than unlink one anchor.
    check shardFileCount(dir) > 2

    check p.close() == 1                        # PRIMARY ASSERTION: reported
    check (not fileExists(keptPath))            # the released chain IS cleaned
    check fileExists(droppedPath)               # PRIMARY ASSERTION: the dropped
                                                # one is NOT — close leaves it
    destroySetPool(p)
    check p == nil
    check shardFileCount(dir) == 0              # PRIMARY ASSERTION: destroy
                                                # sweeps what close would not

  test "destroySetPool_frees_the_pools_own_buffers":
    # `SetPoolObj` lives in `allocShared0` memory, which carries NO destructor,
    # so whatever its GC'd fields still own when `deallocShared` runs is
    # orphaned. `p.idle.setLen(0)` looks like it releases the idle list but only
    # destroys the ELEMENTS and keeps the seq's payload buffer — valgrind:
    # "136 bytes in 1 blocks are definitely lost ... newSeqPayloadUninit <-
    # add(var seq[PooledChain]) <- pool::release". A host that creates a pool
    # per build, or per worker generation, leaks that buffer every time.
    #
    # The oracle is the SHARED heap's occupancy across many complete pool
    # lifecycles: a leaked block is never freed, so with the defect the number
    # only climbs. MEASURED over the 300 cycles below: 43 200 bytes of growth
    # with `setLen(0)`, ZERO with `= @[]`. The bound is set far under the
    # defect's growth and far over the shipped build's, so it is neither a
    # tripwire on allocator noise nor a rubber stamp.
    when not declared(getOccupiedSharedMem):
      # `-d:useMalloc` (the sanitizer build of this file) routes allocation
      # through the C allocator and does not declare Nim's shared-heap counters
      # at all. That is exactly the build under which `just test-valgrind`
      # measures this property directly, so decline rather than pass emptily.
      skip()
    else:
      const
        warmup = 20
        cycles = 300
        maxGrowthBytes = 4096
      let dir = freshDir("destroyleak")
      defer: removeDir(dir)

      proc oneLifecycle(dir: string; tag: string) =
        var p = newSetPool(dir, "io-mon", shard0Cap = 32, shard0ArenaCap = 1024,
          maxIdle = 4)
        for r in 0 ..< 4:
          var l = p.acquire(tag & "-" & $r)
          doAssert l.available
          l.release()
        doAssert p.idleChains > 0        # the seq whose buffer is at issue
        destroySetPool(p)
        doAssert p == nil

      for i in 0 ..< warmup: oneLifecycle(dir, "warm" & $i)
      let before = getOccupiedSharedMem()
      for i in 0 ..< cycles: oneLifecycle(dir, "cyc" & $i)
      let growth = getOccupiedSharedMem() - before
      echo "  [pool shutdown] shared-heap growth over ", cycles,
        " pool lifecycles: ", growth, " bytes"
      check growth < maxGrowthBytes               # PRIMARY ASSERTION
      check shardFileCount(dir) == 0              # ...and nothing on disk either
