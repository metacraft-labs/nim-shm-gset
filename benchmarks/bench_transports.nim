## M1 transport head-to-head benchmark (io-mon-Lossless-Event-Capture).
##
## Drives BOTH lossless shared-memory transports under the SAME synthetic
## max-contention probe-storm workload through a common producer/consumer shape,
## and prints the decision numbers:
##
##   * Candidate C — `nim-shm-set` (sharded grow-only set, dedup at source).
##   * Candidate A — `nim-shm-queue` ring with the `opBlockProducer` policy
##     (lossless block-on-full ring; consumer drains continuously).
##
## Workload: `nProc` fork producers, a SHARED universe of `D` distinct deps
## (models many processes re-reading the same headers). Each producer emits every
## dep `rounds` times in a permuted order, so the ground truth is exactly
## `{0..D-1}` and total events = nProc*D*rounds ≫ D (the probe-storm shape).
##
## Metrics: throughput (events/s), worst-child p99 producer latency, parent
## (consumer) CPU, shared-memory footprint + peak RSS, shard-append count and
## distinct-vs-events ratio (set), and the ground-truth oracle (final ==
## union(intended): ZERO loss, ZERO phantom). A final scenario demonstrates LF-4
## (no hang when the consumer is killed) for both models.
##
## Build:
##   nim c -r --threads:on -d:release --path:src \
##     --path:../nim-shm-queue/src benchmarks/bench_transports.nim

import std/[os, posix, sets, sequtils, monotimes, times, algorithm,
  strutils, strformat]
import shm_set
import shm_queue/ring as ring

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

# --- config ---------------------------------------------------------------
const
  D = 5000            ## distinct deps (the true set size)
  nProc = 6           ## concurrent producer processes
  rounds = 40         ## re-observations of each dep per producer (dup factor)
  totalEvents = nProc * D * rounds

type BenchResult = object
  name: string
  wallSec: float
  eventsPerSec: float
  p99Ns: int64
  consumerCpuSec: float
  shmBytes: int64
  peakRssKb: int64
  shards: int
  distinctFound: int
  lossOrPhantom: bool

# --- helpers --------------------------------------------------------------

proc depBytes(id: int): seq[byte] =
  let s = "dep-" & $id & ".h"
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc parseDepId(b: openArray[byte]): int =
  ## inverse of depBytes: "dep-<id>.h" -> id
  var s = newString(b.len)
  for i in 0 ..< b.len: s[i] = char(b[i])
  let a = s.find('-') + 1
  let z = s.find('.', a)
  result = parseInt(s[a ..< z])

proc permForProducer(c: int): seq[int] =
  ## A cheap per-producer permutation of 0..<D (xorshift-ordered) so producers
  ## touch the shared universe in different orders (contention), while still
  ## covering every id.
  result = newSeq[int](D)
  for i in 0 ..< D: result[i] = i
  var x = uint32(0x9E3779B9'u32) xor uint32(uint64(c) * 2654435761'u64)
  for i in countdown(D - 1, 1):
    x = x xor (x shl 13); x = x xor (x shr 17); x = x xor (x shl 5)
    let j = int(x mod uint32(i + 1))
    swap(result[i], result[j])

proc p99Of(samples: var seq[int64]): int64 =
  if samples.len == 0: return 0
  sort(samples)
  samples[min(samples.high, (samples.len * 99) div 100)]

proc readPeakRssKb(): int64 =
  when defined(linux):
    try:
      for line in lines("/proc/self/status"):
        if line.startsWith("VmHWM:"):
          let parts = line.splitWhitespace()
          return parseBiggestInt(parts[1])
    except CatchableError: discard
  0

proc dirBytes(dir, prefix: string): int64 =
  try:
    for _, p in walkDir(dir):
      if extractFilename(p).startsWith(prefix):
        result += getFileSize(p)
  except CatchableError: discard

proc cpuSecondsSelf(): float =
  var ru: Rusage
  discard getrusage(RUSAGE_SELF, addr ru)
  float(ru.ru_utime.tv_sec) + float(ru.ru_utime.tv_usec) / 1e6 +
    float(ru.ru_stime.tv_sec) + float(ru.ru_stime.tv_usec) / 1e6

# --- Candidate C: nim-shm-set ---------------------------------------------

proc runSet(dir, tag, label: string; shard0Cap, shard0ArenaCap: int): BenchResult =
  result.name = label
  var s = createSet(dir, tag, shard0Cap = shard0Cap,
    shard0ArenaCap = shard0ArenaCap)
  doAssert s.available
  let path0 = s.path0
  let cpu0 = cpuSecondsSelf()
  let t0 = getMonoTime()
  var pids: seq[Pid]
  for c in 0 ..< nProc:
    let pid = fork()
    if pid == 0:
      var cs = attachSet(path0)
      if not cs.available: quitChild(2)
      let perm = permForProducer(c)
      var lat = newSeq[int64](D)  # one sample per distinct id (first round)
      for r in 0 ..< rounds:
        for i in 0 ..< D:
          let e = depBytes(perm[i])
          if r == 0:
            let s0 = getMonoTime()
            if cs.insert(e) == isUnavailable: quitChild(3)
            lat[i] = (getMonoTime() - s0).inNanoseconds
          else:
            if cs.insert(e) == isUnavailable: quitChild(3)
      var p99 = p99Of(lat)
      writeFile(dir / (tag & ".res." & $c), $p99)
      cs.detach(); quitChild(0)
    else: pids.add(pid)
  for pid in pids:
    var st: cint
    discard waitpid(pid, st, 0)
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0
  result.wallSec = (getMonoTime() - t0).inNanoseconds.float / 1e9
  result.consumerCpuSec = cpuSecondsSelf() - cpu0  # ~0: no drain loop
  result.eventsPerSec = totalEvents.float / result.wallSec
  # oracle: exact union {0..D-1}
  var found = initHashSet[int]()
  for e in s.items: found.incl parseDepId(e)
  result.distinctFound = found.len
  result.lossOrPhantom = (found.len != D) or (found != toHashSet(toSeq(0 ..< D)))
  result.shards = s.shardCount()
  result.shmBytes = dirBytes(dir, tag & ".")
  for c in 0 ..< nProc:
    result.p99Ns = max(result.p99Ns,
      parseBiggestInt(readFile(dir / (tag & ".res." & $c))))
  result.peakRssKb = readPeakRssKb()
  s.detach()

# --- Candidate A: nim-shm-queue ring, opBlockProducer ---------------------

proc runRing(dir: string): BenchResult =
  result.name = "A: nim-shm-queue ring (opBlockProducer)"
  let path = dir / "bench-ring.seg"
  var r = createBlockingRing(path, 4096, 64, ring.bootId())
  doAssert r.isValid
  r.registerConsumer()
  let cpu0 = cpuSecondsSelf()
  let t0 = getMonoTime()
  var pids: seq[Pid]
  for c in 0 ..< nProc:
    let pid = fork()
    if pid == 0:
      var pr = attachBlockingRing(path)
      if not pr.isValid: quitChild(2)
      let perm = permForProducer(c)
      var lat = newSeq[int64](D)
      for rnd in 0 ..< rounds:
        for i in 0 ..< D:
          let e = depBytes(perm[i])
          if rnd == 0:
            let s0 = getMonoTime()
            if pr.tryPush(e) != prPushed: quitChild(3)  # block policy: no drop
            lat[i] = (getMonoTime() - s0).inNanoseconds
          else:
            if pr.tryPush(e) != prPushed: quitChild(3)
      writeFile(dir / ("rres." & $c), $p99Of(lat))
      pr.detach(); quitChild(0)
    else: pids.add(pid)
  # CONSUMER: drain continuously into a dedup set until all producers done AND
  # the ring is empty. This is the ring's two-sided busy-wait cost.
  var found = initHashSet[int]()
  var outBuf = newSeq[byte](64)
  var liveKids = pids.len
  while liveKids > 0 or r.pendingCount() > 0:
    var outLen = 0
    if r.tryDrainOne(outBuf, outLen) == drGot:
      found.incl parseDepId(outBuf.toOpenArray(0, outLen - 1))
    else:
      # reap any finished children (non-blocking) so we exit once all done+empty
      var st: cint
      let w = waitpid(-1, st, WNOHANG)
      if w > 0: dec liveKids
  for pid in pids:
    var st: cint
    discard waitpid(pid, st, 0)  # already reaped some; harmless
  result.wallSec = (getMonoTime() - t0).inNanoseconds.float / 1e9
  result.consumerCpuSec = cpuSecondsSelf() - cpu0  # drain loop CPU
  result.eventsPerSec = totalEvents.float / result.wallSec
  result.distinctFound = found.len
  result.lossOrPhantom = (found.len != D) or (found != toHashSet(toSeq(0 ..< D)))
  result.shards = 1
  result.shmBytes = dirBytes(dir, "bench-ring.")
  for c in 0 ..< nProc:
    result.p99Ns = max(result.p99Ns, parseBiggestInt(readFile(dir / ("rres." & $c))))
  result.peakRssKb = readPeakRssKb()
  doAssert r.droppedCount() == 0
  r.markConsumerGone()
  r.detach()

# --- LF-4: no hang when the consumer is killed ----------------------------

proc lf4SetDemo(dir: string): string =
  ## Candidate C: producers NEVER block (idempotent inserts, no backpressure), so
  ## a killed consumer cannot hang a producer. Kill the consumer mid-run; the
  ## producer keeps inserting and finishes; its data persists in the file.
  var s = createSet(dir, "lf4set", shard0Cap = 256, shard0ArenaCap = 32 * 1024)
  doAssert s.available
  let path0 = s.path0
  # A "consumer" child that just holds the map then gets killed.
  let cons = fork()
  if cons == 0:
    var cs = attachSet(path0)
    while true: discard sched_yield()  # (killed by parent)
  let prod = fork()
  if prod == 0:
    var ps = attachSet(path0)
    if not ps.available: quitChild(2)
    for i in 0 ..< 20000:
      discard ps.insert(depBytes(i mod 512))
    ps.detach(); quitChild(0)
  discard kill(cons, SIGKILL)  # consumer dies mid-run
  var st: cint
  discard waitpid(cons, st, 0)
  # The producer must finish within a bounded time (never hang on the dead peer).
  let deadline = epochTime() + 10.0
  var done = false
  while epochTime() < deadline:
    if waitpid(prod, st, WNOHANG) == prod: done = true; break
    discard sched_yield()
  if not done:
    discard kill(prod, SIGKILL); discard waitpid(prod, st, 0)
    return "FAIL: producer hung after consumer killed"
  doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0
  s.detach()
  "PASS: producer finished with no hang after consumer SIGKILL (structural: " &
    "inserts never block)"

proc lf4RingDemo(dir: string): string =
  ## Candidate A: producers BLOCK on a full ring; a killed consumer must yield
  ## prConsumerGone (bounded), never an unbounded hang.
  let path = dir / "lf4-ring.seg"
  var r = createBlockingRing(path, 8, 32, ring.bootId())
  doAssert r.isValid
  r.registerConsumer()  # parent registers, then "dies" by deregistering+exit-sim
  # Fill the ring so the next push blocks.
  for i in 0 ..< 8: doAssert r.tryPush(depBytes(i)) == prPushed
  let prod = fork()
  if prod == 0:
    var pr = attachBlockingRing(path)
    if not pr.isValid: quitChild(2)
    # This push blocks (ring full). When the consumer is marked gone it must
    # return prConsumerGone, not hang.
    let res = pr.tryPush(depBytes(99))
    pr.detach()
    quitChild(if res == prConsumerGone: 0 else: 4)
  discard usleep(50_000)       # let the child reach the blocking wait
  r.markConsumerGone()         # consumer announces it is gone (+futex wake)
  let deadline = epochTime() + 10.0
  var st: cint
  var done = false
  while epochTime() < deadline:
    if waitpid(prod, st, WNOHANG) == prod: done = true; break
    discard sched_yield()
  if not done:
    discard kill(prod, SIGKILL); discard waitpid(prod, st, 0)
    r.detach(); return "FAIL: blocked producer hung after consumer gone"
  r.detach()
  if WIFEXITED(st) and WEXITSTATUS(st) == 0:
    "PASS: blocked producer returned prConsumerGone (no hang) after consumer gone"
  else:
    "FAIL: producer exited " & $WEXITSTATUS(st) & " (expected prConsumerGone)"

# --- report ---------------------------------------------------------------

proc row(r: BenchResult) =
  echo &"  {r.name}"
  echo &"    wall               : {r.wallSec:8.3f} s"
  echo &"    throughput         : {r.eventsPerSec/1e6:8.3f} M events/s  ({totalEvents} events)"
  echo &"    p99 producer lat   : {r.p99Ns:8} ns   (worst child)"
  echo &"    consumer CPU       : {r.consumerCpuSec:8.3f} s"
  echo &"    shm footprint      : {r.shmBytes div 1024:8} KiB"
  echo &"    peak RSS (parent)  : {r.peakRssKb:8} KiB"
  echo &"    shard-appends      : {r.shards:8}"
  echo &"    distinct found     : {r.distinctFound:8}   (truth = {D})"
  echo &"    zero-loss/phantom  : {(not r.lossOrPhantom)}"

when isMainModule:
  let dir = getTempDir() / ("shmset-bench-" & $getpid())
  removeDir(dir); createDir(dir)
  echo "io-mon Lossless Event Capture — M1 transport benchmark"
  echo &"workload: {nProc} producers x {D} distinct x {rounds} rounds = " &
    &"{totalEvents} events, dedup ratio {totalEvents div D}x"
  echo ""
  # Candidate C, growing by sharding (small shard0 -> several shard-appends).
  let setRes = runSet(dir, "sharded", "C: nim-shm-set (sharded G-Set)",
    shard0Cap = 1024, shard0ArenaCap = 128 * 1024)
  # Candidate C size-once baseline: shard0 pre-sized past the distinct count so
  # it NEVER shards — isolates the per-insert cost from the sharding overhead.
  let setOnce = runSet(dir, "sizeonce",
    "C': nim-shm-set (size-once, no growth)",
    shard0Cap = 16384, shard0ArenaCap = 4 * 1024 * 1024)
  let ringRes = runRing(dir)
  row(setRes); echo ""
  row(setOnce); echo ""
  row(ringRes); echo ""
  echo "LF-1 (zero loss / zero phantom, all lossless models): ",
    (not setRes.lossOrPhantom) and (not setOnce.lossOrPhantom) and
    (not ringRes.lossOrPhantom)
  echo "LF-4 killed-consumer:"
  echo "  ", lf4SetDemo(dir)
  echo "  ", lf4RingDemo(dir)
  removeDir(dir)
