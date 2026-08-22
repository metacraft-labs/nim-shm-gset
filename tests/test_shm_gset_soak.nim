## Bounded high-contention many-process soak + ground-truth oracle
## (design spec §4.5(f)). Forces TINY shards so growth-by-sharding runs constantly
## across many producer processes for a bounded, parameterizable duration, then
## asserts `snapshot == union(intended)` (zero loss, zero phantom) and
## `growthFailures == 0`.
##
## Duration via `SHM_GSET_SOAK_SECONDS` (default 2.0s, kept short so `just test`
## stays fast). The MULTI-HOUR soak and `rr`-chaos mode on x86 AND ARM64 are a
## CI / M2-part-2 concern (see the milestone status).
##
## PHASE 2 — `recycle_soak` (HM-3). The same harness driven through the HOST-SIDE
## RECYCLING POOL (`shm_gset/pool`): many successive recycles of ONE chain, each
## round with an input set disjoint from every other round's, and the oracle is
## that each generation's union equals EXACTLY its intended set — not a superset
## (leakage from the previous action, the cardinal sin) and not a subset (loss).
## This is the end-to-end proof that recycling under the pool cannot
## cross-attribute, with real forked producers rather than in-process inserts.
## Round count via `SHM_GSET_RECYCLE_ROUNDS` (default 20).

import std/[os, posix, sets, strutils, times]
import shm_gset
import shm_gset/transport
import shm_gset/pool

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

when isMainModule:
  let soakSecs = try: parseFloat(getEnv("SHM_GSET_SOAK_SECONDS", "2.0"))
                 except ValueError: 2.0
  const
    nProc = 6
    perProc = 1200        ## distinct per producer
  let dir = getTempDir() / ("shmgset-soak-" & $getpid())
  removeDir(dir); createDir(dir)
  # Tiny shards ⇒ maximal sharding / constant concurrent growth (§4.5(d)).
  var host = createSet(dir, "io-mon", "edge", shard0Cap = 16, shard0ArenaCap = 512)
  doAssert host.available
  let path0 = host.path0

  echo "soak: ", nProc, " producers x ", perProc, " distinct, ",
    soakSecs, "s, tiny shards"

  var pids: seq[Pid]
  for c in 0 ..< nProc:
    let pid = fork()
    if pid == 0:
      var s = attachSet(path0)
      if not s.available: quitChild(2)
      let deadline = epochTime() + soakSecs
      # Re-insert the whole intended subset repeatedly (probe-storm shape) until
      # the deadline; every insert must be accepted or a known duplicate.
      while epochTime() < deadline:
        for j in 0 ..< perProc:
          case s.insert(bytesOf("c" & $c & "/" & $j))
          of isInserted, isExists: discard
          else: (s.detach(); quitChild(3))
      s.detach(); quitChild(0)
    else:
      doAssert pid > 0
      pids.add pid
  for pid in pids:
    var st: cint
    doAssert waitpid(pid, st, 0) == pid
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0, "a soak producer failed"

  var expected = initHashSet[string]()
  for c in 0 ..< nProc:
    for j in 0 ..< perProc: expected.incl("c" & $c & "/" & $j)
  var got = initHashSet[string]()
  for e in host.items: got.incl strOf(e)
  doAssert got.len == expected.len,
    "loss/phantom: got " & $got.len & " want " & $expected.len
  doAssert got == expected                 # zero loss, zero phantom
  doAssert host.growthFailures() == 0      # no SIGNALLED saturation
  host.assertNoAbsolutePointers()
  let sc = host.shardCount()
  let cs = host.claimedSlots()
  host.detach()
  removeDir(dir)
  echo "[OK] soak oracle: distinct=", got.len, " shards=", sc,
    " claimedSlots(UB)=", cs, " growthFailures=0"

  # -------------------------------------------------------------------------
  # PHASE 2 — recycle_soak (HM-3): N successive recycles through the POOL, with
  # DISJOINT input sets, oracle = exact union per generation.
  # -------------------------------------------------------------------------
  let rounds = try: parseInt(getEnv("SHM_GSET_RECYCLE_ROUNDS", "20"))
               except ValueError: 20
  const
    rcProc = 4
    rcPer = 500
  let rcDir = getTempDir() / ("shmgset-recycle-soak-" & $getpid())
  removeDir(rcDir); createDir(rcDir)
  var gsetPool = newSetPool(rcDir, "io-mon", shard0Cap = 16, shard0ArenaCap = 512,
    maxIdle = 2)
  echo "recycle soak: ", rounds, " recycles x ", rcProc, " producers x ",
    rcPer, " distinct, tiny shards"

  var anchors = initHashSet[string]()
  var shardsPerRound: seq[int]
  for round in 0 ..< rounds:
    var lease = gsetPool.acquire("gen-" & $round)
    doAssert lease.available, "the pool refused to acquire a chain"
    let p0 = lease.path0
    anchors.incl p0
    # The chain must arrive EMPTY and carrying THIS round's identity: the pool
    # owns the reset, so this is what "was reset" looks like from outside.
    doAssert lease.snapshot().len == 0, "a recycled chain was not empty"
    doAssert lease.runId == "gen-" & $round

    let tag = "g" & $round
    var kids: seq[Pid]
    for c in 0 ..< rcProc:
      let pid = fork()
      if pid == 0:
        var pr = attachProducer(p0)
        if not pr.available: quitChild(2)
        for j in 0 ..< rcPer:
          if pr.emit(bytesOf(tag & "/c" & $c & "/" & $j)) notin
              {emInserted, emExists}:
            pr.detach(); quitChild(3)
        pr.detach(); quitChild(0)
      else:
        doAssert pid > 0
        kids.add pid
    for pid in kids:
      var st: cint
      doAssert waitpid(pid, st, 0) == pid
      doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
        "a recycle-soak producer failed in round " & $round

    var want = initHashSet[string]()
    for c in 0 ..< rcProc:
      for j in 0 ..< rcPer: want.incl(tag & "/c" & $c & "/" & $j)
    var have = initHashSet[string]()
    for e in lease.items: have.incl strOf(e)
    # THE ORACLE. Equality both ways: `have - want` is leakage from an earlier
    # generation, `want - have` is loss in this one.
    doAssert have == want,
      "round " & $round & ": union != intended (extra " &
      $(have - want).len & ", missing " & $(want - have).len & ")"
    for e in have:
      doAssert e.startsWith(tag & "/"),
        "round " & $round & " observed a foreign element: " & e
    doAssert lease.growthFailures() == 0'u64
    shardsPerRound.add lease.shardCount()
    lease.release()

  # One chain served every round, and it stopped growing after the warmup.
  doAssert anchors.len == 1, "the pool did not recycle: " & $anchors.len & " chains"
  for r in 1 ..< shardsPerRound.len:
    doAssert shardsPerRound[r] == shardsPerRound[0],
      "the chain grew after warmup: " & $shardsPerRound
  let rcStats = gsetPool.stats
  doAssert rcStats.createdChains == 1
  doAssert rcStats.recycledAcquires == rounds - 1
  doAssert gsetPool.close() == 0
  var leftover = 0
  for _, p in walkDir(rcDir):
    if ".shard" in extractFilename(p): inc leftover
  doAssert leftover == 0, "the pool leaked " & $leftover & " shard files"
  removeDir(rcDir)
  echo "[OK] recycle soak oracle: ", rounds, " generations x ",
    rcProc * rcPer, " distinct, exact union each time, ",
    shardsPerRound[0], " shards linked once, 0 files leaked"
