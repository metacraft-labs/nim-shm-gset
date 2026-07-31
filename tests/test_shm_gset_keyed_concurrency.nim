## CONCURRENCY properties of the parameterised key discipline — multi-PROCESS
## (fork) and multi-THREAD writers, following the conventions of
## `test_shm_gset_concurrency.nim` and `test_shm_gset_threads.nim`: real
## processes, real threads, real `mmap`-backed shards, a ground-truth oracle.
##
## The central oracle throughout is WALK-VS-UNION AGREEMENT: for every edge, the
## probe-run walk from `h(weak)` must yield exactly the elements that the
## single-threaded union over all shards holds for that weak fingerprint. It is
## the sharpest statement of "no lost element, no phantom element, no early
## termination" for a multimap with no stored chain — the two enumerations reach
## the elements by completely different routes (one follows the probe run, the
## other scans every slot of every shard) and must still agree exactly.

import std/[os, posix, sets, strutils, tables, unittest]
import shm_gset
import ac_index_model

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-kc-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result); createDir(result)

proc hexOf(b: openArray[byte]): string =
  result = newStringOfCap(b.len * 2)
  for x in b: result.add toHex(x.int, 2)

proc hexOf(b: Fp32): string = hexOf(b.toOpenArray(0, 31))

proc unionForWeak(s: var ShmGSetT[AcIndexKey]; weak: Fp32): HashSet[string] =
  ## Every element the WHOLE-CHAIN union holds for this weak fingerprint, found
  ## by scanning every slot of every shard — the route that does not use the
  ## probe run at all.
  result = initHashSet[string]()
  for e in s.items:
    if acIsWellFormed(e) and acWeak(e) == weak: result.incl hexOf(e)

proc walkForWeak(s: var ShmGSetT[AcIndexKey]; weak: Fp32): HashSet[string] =
  ## Every element the PROBE-RUN walk yields for this weak fingerprint.
  result = initHashSet[string]()
  for v in s.withPrimaryKey(weak):
    if acIsWellFormed(v.bytes) and acWeak(v.bytes) == weak:
      result.incl hexOf(v.bytes)

# ---------------------------------------------------------------------------

suite "H1. concurrent claims into ONE probe run (multi-process)":

  test "N processes fill a single edge's run; the walk finds every element":
    # The hardest case for a chain-free multimap: every writer contends for the
    # SAME home slot, so the run is built by interleaved CAS winners and losers,
    # and every loser probes forward past a slot another process just claimed.
    let dir = freshDir("onerun")
    defer: removeDir(dir)
    const
      nProc = 4
      perProc = 120
      dupFactor = 3
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 1024, shard0ArenaCap = 1 shl 20)
    check s.available
    let path0 = s.path0
    let weak = fpOf("hot-edge")
    let foreign = fpOf("foreign-edge")

    var pids: seq[Pid]
    for c in 0 ..< nProc:
      let pid = fork()
      if pid == 0:
        var cs = attachSetT(path0, AcIndexKey)
        if not cs.available: quitChild(2)
        for j in 0 ..< perProc:
          let e = acRecord(weak, fpOf("hot-s-" & $c & "-" & $j), 0)
          for _ in 0 ..< dupFactor:           # probe storm: re-observe
            if cs.insert(e) notin {isInserted, isExists}:
              cs.detach(); quitChild(3)
        # a foreign edge, so the hot run is interleaved with another key's bytes
        if cs.insert(acRecord(foreign, fpOf("foreign-s-" & $c), 0)) notin
           {isInserted, isExists}:
          cs.detach(); quitChild(4)
        cs.detach(); quitChild(0)
      else:
        check pid > 0
        pids.add pid
    for pid in pids:
      var st: cint
      check waitpid(pid, st, 0) == pid
      check WIFEXITED(st) and WEXITSTATUS(st) == 0

    var expected = initHashSet[string]()
    for c in 0 ..< nProc:
      for j in 0 ..< perProc:
        expected.incl hexOf(acRecord(weak, fpOf("hot-s-" & $c & "-" & $j), 0))
    let walked = s.walkForWeak(weak)
    check walked == expected                  # zero loss, zero phantom
    check walked == s.unionForWeak(weak)      # walk == union
    var foreignExpected = initHashSet[string]()
    for c in 0 ..< nProc:
      foreignExpected.incl hexOf(acRecord(foreign, fpOf("foreign-s-" & $c), 0))
    check s.walkForWeak(foreign) == foreignExpected
    check s.growthFailures() == 0
    s.assertNoAbsolutePointers()
    echo "  [one-run oracle] elements=", walked.len, " shards=", s.shardCount()
    s.detach()

# ---------------------------------------------------------------------------

var gPath0: string
var gEdges: int
var gPerEdge: int

proc keyedInserter(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var s = attachSetT(gPath0, AcIndexKey)
    doAssert s.available
    for i in 0 ..< gEdges:
      let w = fpOf("th-edge-" & $i)
      for j in 0 ..< gPerEdge:
        let e = acRecord(w, fpOf("th-s-" & $id & "-" & $i & "-" & $j), 0)
        doAssert s.insert(e) in {isInserted, isExists}
    s.detach()

suite "H2. concurrent claims across MANY runs (threads, heavy sharding)":

  test "every element of every edge is re-found by its own probe-run walk":
    let dir = freshDir("threads")
    defer: removeDir(dir)
    const nThreads = 5
    var host = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 64, shard0ArenaCap = 4096)   # tiny: concurrent grow + sharding
    check host.available
    gPath0 = host.path0
    gEdges = 25
    gPerEdge = 6

    var ts = newSeq[Thread[int]](nThreads)
    for i in 0 ..< nThreads: createThread(ts[i], keyedInserter, i)
    for i in 0 ..< nThreads: joinThread(ts[i])

    check host.shardCount() > 2                # it really did shard concurrently
    for i in 0 ..< gEdges:
      let w = fpOf("th-edge-" & $i)
      var expected = initHashSet[string]()
      for id in 0 ..< nThreads:
        for j in 0 ..< gPerEdge:
          expected.incl hexOf(
            acRecord(w, fpOf("th-s-" & $id & "-" & $i & "-" & $j), 0))
      let walked = host.walkForWeak(w)
      check walked == expected                 # complete under concurrent claims
      check walked == host.unionForWeak(w)     # walk == union
    check host.growthFailures() == 0
    host.assertNoAbsolutePointers()
    host.detach()

# ---------------------------------------------------------------------------

suite "H3. concurrent records AND tombstones converge":

  test "liveness is a pure function of the converged element set":
    # Writers race records, evictions and resurrections over a shared key pool.
    # We deliberately do NOT predict which keys end up live — that depends on the
    # interleaving. What must hold is CONVERGENCE: every reader, by either
    # enumeration route, sees the same element set and therefore reaches the same
    # verdict; nothing outside the intended identity space ever appears; and no
    # key is simultaneously reported live and dead.
    let dir = freshDir("tombrace")
    defer: removeDir(dir)
    const
      nProc = 4
      nKeys = 30
      rounds = 6
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 128, shard0ArenaCap = 1 shl 16)
    check s.available
    let path0 = s.path0
    let weak = fpOf("race-edge")

    var pids: seq[Pid]
    for c in 0 ..< nProc:
      let pid = fork()
      if pid == 0:
        var cs = attachSetT(path0, AcIndexKey)
        if not cs.available: quitChild(2)
        for r in 0 ..< rounds:
          for k in 0 ..< nKeys:
            let strong = fpOf("race-s-" & $k)
            if (k + c + r) mod 3 == 0:
              if cs.acEvict(akRecord, weak, strong) notin
                 {isInserted, isExists}: quitChild(3)
            else:
              if cs.acInsert(akRecord, weak, strong) notin
                 {isInserted, isExists}: quitChild(4)
        cs.detach(); quitChild(0)
      else:
        check pid > 0
        pids.add pid
    for pid in pids:
      var st: cint
      check waitpid(pid, st, 0) == pid
      check WIFEXITED(st) and WEXITSTATUS(st) == 0

    # 1. No phantom: every element in the chain is one of the intended identities
    #    for this edge, well-formed, with a generation the counter dominates.
    var intended = initHashSet[string]()
    for k in 0 ..< nKeys:
      intended.incl acIdentity(acRecord(weak, fpOf("race-s-" & $k), 0))
    let counter = s.controlWord(AcGenWord)
    var seen = 0
    for e in s.items:
      check acIsWellFormed(e)
      check acIdentity(e) in intended
      check acGeneration(e) <= counter        # the generation invariant holds
      inc seen
    check seen > 0

    # 2. Walk == union for the edge (no lost element, no early termination).
    check s.walkForWeak(weak) == s.unionForWeak(weak)

    # 3. Every reader agrees: an independent attachment reaches the identical
    #    verdict, key by key, and each key is live-or-dead, never both.
    var view = attachSetT(path0, AcIndexKey)
    check view.available
    let a = s.acScanEdge(weak)
    let b = view.acScanEdge(weak)
    var liveA, liveB: HashSet[string]
    liveA = initHashSet[string](); liveB = initHashSet[string]()
    for id in a.liveIdentities: liveA.incl id
    for id in b.liveIdentities: liveB.incl id
    check liveA == liveB
    for id in intended:
      let isLiveA = id in liveA
      check isLiveA == (id in liveB)
      # live iff a record exists and no tombstone is strictly newer — recomputed
      # here from the raw element set, independently of `acScanEdge`.
      var newestRec = -1'i64
      var newestTomb = -1'i64
      for e in s.items:
        if acIdentity(e) != id: continue
        if acIsTombstone(e): newestTomb = max(newestTomb, int64(acGeneration(e)))
        else: newestRec = max(newestRec, int64(acGeneration(e)))
      check isLiveA == (newestRec >= 0 and newestTomb <= newestRec)
    check s.growthFailures() == 0
    echo "  [tombstone race] keys=", nKeys, " live=", liveA.len,
      " elements=", seen, " shards=", s.shardCount(), " gen=", counter
    view.detach(); s.detach()

# ---------------------------------------------------------------------------

suite "H4. a reader walking a run concurrently with a flatten":

  test "nothing observable before the flatten becomes unobservable after":
    # The flattener copies a shard's elements FORWARD, then marks it drained,
    # then unlinks it. A reader walks shards OLDEST-FIRST, so it sees each
    # element in the source, in the destination, or in both — never in neither.
    # Here a forked reader loops that walk for the whole duration of the flatten
    # and fails the moment any expected element is missing from ANY iteration.
    let dir = freshDir("flatrace")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 16, shard0ArenaCap = 512)   # tiny: forces a multi-shard chain
    check s.available
    let path0 = s.path0
    const nEdges = 60
    var expected = initTable[string, HashSet[string]]()
    for i in 0 ..< nEdges:
      let w = fpOf("fr-edge-" & $i)
      var es = initHashSet[string]()
      for j in 0 .. (i mod 3):
        let e = acRecord(w, fpOf("fr-s-" & $i & "-" & $j), 0)
        check s.insert(e) in {isInserted, isExists}
        es.incl hexOf(e)
      expected[hexOf(w)] = es
    check s.shardCount() >= 3

    # Reader child: loop the per-edge walk until the flattener signals it is
    # done (plus a hard iteration cap so the test can never hang). EVERY
    # iteration must be complete.
    let doneFile = dir / "flatten-done"
    let reader = fork()
    if reader == 0:
      var rs = attachSetT(path0, AcIndexKey)
      if not rs.available: quitChild(2)
      var iter = 0
      var sawDone = false
      while iter < 100_000 and not sawDone:
        sawDone = fileExists(doneFile)   # one more full pass AFTER the signal
        for i in 0 ..< nEdges:
          let w = fpOf("fr-edge-" & $i)
          var got = initHashSet[string]()
          for v in rs.withPrimaryKey(w):
            if acIsWellFormed(v.bytes) and acWeak(v.bytes) == w:
              got.incl hexOf(v.bytes)
          for want in expected[hexOf(w)]:
            if want notin got:
              rs.detach(); quitChild(5)       # an element became unobservable
        inc iter
      rs.detach(); quitChild(0)
    check reader > 0

    # Flattener (this process): copy forward -> drain -> retire, for every shard
    # below the newest, while the reader is walking.
    let newest = s.shardCount() - 1
    for k in 1 ..< newest:
      var copied: seq[seq[byte]]
      for v in s.shardElements(k): copied.add v.toBytesSeq()
      for e in copied: check s.insert(e) in {isInserted, isExists}
      check s.markShardDrained(k)
      check s.retireShard(k)
    writeFile(doneFile, "done")

    var st: cint
    check waitpid(reader, st, 0) == reader
    check WIFEXITED(st)
    check WEXITSTATUS(st) == 0                # the reader never saw a gap

    # And the post-flatten chain is still complete for every edge.
    for i in 0 ..< nEdges:
      let w = fpOf("fr-edge-" & $i)
      check s.walkForWeak(w) == expected[hexOf(w)]
      check s.walkForWeak(w) == s.unionForWeak(w)
    echo "  [flatten race] retired shards 1..", newest - 1, " of ",
      s.shardCount()
    s.detach()
