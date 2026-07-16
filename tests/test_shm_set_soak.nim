## Bounded high-contention many-process soak + ground-truth oracle
## (design spec §4.5(f)). Forces TINY shards so growth-by-sharding runs constantly
## across many producer processes for a bounded, parameterizable duration, then
## asserts `snapshot == union(intended)` (zero loss, zero phantom) and
## `growthFailures == 0`.
##
## Duration via `SHM_SET_SOAK_SECONDS` (default 2.0s, kept short so `just test`
## stays fast). The MULTI-HOUR soak and `rr`-chaos mode on x86 AND ARM64 are a
## CI / M2-part-2 concern (see the milestone status).

import std/[os, posix, sets, strutils, times]
import shm_set

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

when isMainModule:
  let soakSecs = try: parseFloat(getEnv("SHM_SET_SOAK_SECONDS", "2.0"))
                 except ValueError: 2.0
  const
    nProc = 6
    perProc = 1200        ## distinct per producer
  let dir = getTempDir() / ("shmset-soak-" & $getpid())
  removeDir(dir); createDir(dir)
  # Tiny shards ⇒ maximal sharding / constant concurrent growth (§4.5(d)).
  var host = createSet(dir, "edge", shard0Cap = 16, shard0ArenaCap = 512)
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
