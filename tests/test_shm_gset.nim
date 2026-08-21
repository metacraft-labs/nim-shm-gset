## Functional + concurrency suite for `nim-shm-gset` (Candidate C).
##
## Covers: idempotent membership, dedup-at-source, growth by SHARDING (never
## drop), the single-threaded union/merge, position-independence ACROSS PROCESS
## boundaries (fork → different address space, offsets-only), the ground-truth
## oracle (final == union(intended): zero loss, zero phantom), SIGNALLED
## growth-failure, and the cross-restart reaper.

import std/[os, posix, sets, strutils, unittest]
import shm_gset

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result)
  createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

when defined(linux):
  proc shardFdCount(pathPrefix: string): int =
    for fd in 3 .. 255:
      var buf: array[4096, char]
      let n = posix.readlink(("/proc/self/fd/" & $fd).cstring,
        cast[cstring](addr buf[0]), buf.len)
      if n <= 0:
        continue
      var target = newString(n)
      copyMem(addr target[0], addr buf[0], n)
      if target.startsWith(pathPrefix):
        inc result

# --- basic membership + idempotency ----------------------------------------

suite "membership + idempotent inserts":
  when defined(linux):
    test "mapped shards do not retain backing file descriptors":
      let dir = freshDir("fd-lifetime")
      defer: removeDir(dir)
      var owner = createSet(dir, "io-mon", "edge",
        shard0Cap = 64, shard0ArenaCap = 8192)
      check owner.available
      check shardFdCount(owner.path0) == 0
      var producer = attachSet(owner.path0)
      check producer.available
      check shardFdCount(owner.path0) == 0
      check producer.insert(bytesOf("still-mapped")) == isInserted
      check owner.contains(bytesOf("still-mapped"))
      producer.detach()
      owner.detach()

  test "insert / contains / dedup":
    let dir = freshDir("basic")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check s.available
    check s.insert(bytesOf("alpha")) == isInserted
    check s.insert(bytesOf("beta")) == isInserted
    check s.insert(bytesOf("alpha")) == isExists   # idempotent
    check s.insert(bytesOf("alpha")) == isExists
    check s.contains(bytesOf("alpha"))
    check s.contains(bytesOf("beta"))
    check (not s.contains(bytesOf("gamma")))
    check s.insert(newSeq[byte](0)) == isInserted   # empty element allowed
    check s.contains(newSeq[byte](0))
    let snap = s.snapshot()
    check snap.len == 3                              # alpha, beta, empty
    check s.growthFailures() == 0
    s.detach()

  test "many distinct elements force SHARDING; snapshot is the exact union":
    let dir = freshDir("shard")
    defer: removeDir(dir)
    # Tiny shard0 so growth is forced quickly (load factor 0.5 on 64 slots).
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = 2048)
    check s.available
    var expected = initHashSet[string]()
    for i in 0 ..< 2000:
      let e = "path/to/file-" & $i & ".h"
      expected.incl e
      check s.insert(bytesOf(e)) in {isInserted, isExists}
      # Re-observe (probe storm). Idempotent WITHIN a shard generation; across a
      # growth an element in an older shard is re-added to the newest shard at
      # most once (the harmless cross-shard duplicate the union folds), so both
      # outcomes are valid — what must hold is exactness of the final union.
      check s.insert(bytesOf(e)) in {isInserted, isExists}
    check s.shardCount() > 1                         # it actually sharded
    check s.growthFailures() == 0
    var got = initHashSet[string]()
    for e in s.items: got.incl strOf(e)
    check got.len == expected.len                    # zero loss, zero phantom
    check got == expected
    # Cross-shard duplication is bounded: the claimed-slot UPPER bound stays
    # close to the true distinct count (dedup-at-source works), never blowing up
    # toward the event count.
    check s.claimedSlots() < uint64(expected.len * 2)
    s.detach()

# --- position-independence (offsets only, no absolute pointers) -------------

suite "position-independence (design spec §4.5(b))":
  test "a second independent mapping at a DIFFERENT base sees the same set":
    let dir = freshDir("posindep")
    defer: removeDir(dir)
    var owner = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = 2048)
    check owner.available
    var expected = initHashSet[string]()
    for i in 0 ..< 1500:               # force several shards
      let e = "elem-" & $i
      expected.incl e
      discard owner.insert(bytesOf(e))
    check owner.shardCount() > 1

    # Attach a SECOND view of the same chain in this process. `mmap(nil, …)` picks
    # a fresh virtual address, so this mapping's base differs from `owner`'s — if
    # any absolute pointer had leaked into shared memory, the second view would
    # dereference garbage. Offsets-only ⇒ identical results.
    var view = attachSet(owner.path0)
    check view.available
    check cast[uint](view.shards0Base()) != cast[uint](owner.shards0Base())
    for e in expected:
      check view.contains(bytesOf(e))
    var got = initHashSet[string]()
    for e in view.items: got.incl strOf(e)
    check got == expected
    view.detach(); owner.detach()

# --- ground-truth oracle across MANY fork producers ------------------------

suite "multi-process oracle (zero loss / zero phantom)":
  test "N children each insert an intended set with heavy duplication":
    let dir = freshDir("oracle")
    defer: removeDir(dir)
    const
      nProc = 4
      perProc = 900         # distinct per child
      dupFactor = 8         # re-observe each element 8x (probe-storm shape)
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 128, shard0ArenaCap = 4096)
    check s.available
    let path0 = s.path0

    var pids: seq[Pid]
    for c in 0 ..< nProc:
      let pid = fork()
      if pid == 0:
        var cs = attachSet(path0)
        if not cs.available: quitChild(2)
        for j in 0 ..< perProc:
          let e = bytesOf("c" & $c & "/dep-" & $j)
          for _ in 0 ..< dupFactor:
            if cs.insert(e) notin {isInserted, isExists}:
              cs.detach(); quitChild(3)   # saturation / unavailable = failure
        cs.detach()
        quitChild(0)
      else:
        check pid > 0
        pids.add(pid)

    for pid in pids:
      var st: cint
      check waitpid(pid, st, 0) == pid
      check WIFEXITED(st)
      check WEXITSTATUS(st) == 0

    # ORACLE: the merged set must equal the union of every child's intended set,
    # exactly — no loss, no phantom.
    var expected = initHashSet[string]()
    for c in 0 ..< nProc:
      for j in 0 ..< perProc:
        expected.incl("c" & $c & "/dep-" & $j)
    var got = initHashSet[string]()
    for e in s.items: got.incl strOf(e)
    check got.len == nProc * perProc
    check got == expected
    check s.growthFailures() == 0
    check s.shardCount() >= 1
    echo "  [oracle] distinct=", got.len, " shards=", s.shardCount(),
      " claimedSlots(UB)=", s.claimedSlots()
    s.detach()

# --- reaper -----------------------------------------------------------------

suite "reaper (cross-restart GC)":
  test "a dead-owner run is reaped; a live-owner run is left alone":
    let dir = freshDir("reap")
    defer: removeDir(dir)
    # Live run (this process owns it).
    var live = createSet(dir, "io-mon", "liveEdge", shard0Cap = 32, shard0ArenaCap = 1024)
    check live.available
    check live.insert(bytesOf("x")) == isInserted

    # Dead-owner run: fork a child that creates a set then exits; reap by pid.
    let child = fork()
    if child == 0:
      var cs = createSet(dir, "io-mon", "deadEdge", shard0Cap = 32, shard0ArenaCap = 1024)
      if not cs.available: quitChild(2)
      discard cs.insert(bytesOf("y"))
      # leak on purpose (no detach/unlink) then exit so its pid dies
      quitChild(0)
    var st: cint
    discard waitpid(child, st, 0)

    # The dead run's shard0 exists on disk. The name carries the `io-mon~` appId
    # tag and an opaque chain uniquifier — NOT the runId, which lives in the
    # header — so the dead chain is the one anchor here that is not the live
    # one.
    var deadAnchor = ""
    for _, p in walkDir(dir):
      let n = extractFilename(p)
      if n.startsWith("io-mon~") and n.endsWith(".shard0") and p != live.path0:
        deadAnchor = p
    check deadAnchor.len > 0
    check fileExists(deadAnchor)

    let reaped = reapStaleSegments(dir, "io-mon")
    check reaped >= 1
    check (not fileExists(deadAnchor))      # dead-owner chain removed
    check fileExists(live.path0)            # live-owner chain untouched
    live.detach()

  test "a wrong-bootid run is reaped even though its owner pid is live":
    # Isolates the OTHER staleness axis (§4.3.4): a shard chain that survived a
    # REBOOT ⇒ its recorded boot-id != the current boot-id ⇒ pids are meaningless
    # across the reboot ⇒ reap it, EVEN IF a live process happens to hold the
    # recorded pid on the current boot. We forge a shard0 whose owner pid is THIS
    # (alive) process but whose boot-id is deliberately not the current one, so
    # only the boot-id mismatch — not pid-death — can make it stale.
    let dir = freshDir("reapboot")
    defer: removeDir(dir)
    let wrongBoot = bootId() + 1          # any value != the current boot-id
    let livePid = uint64(getpid())        # a pid that IS alive on this boot
    let stalePrefix = shardBasePrefix(dir, "io-mon", 1'u64, wrongBoot, livePid)
    let staleAnchor = stalePrefix & ".shard0"
    writeFile(staleAnchor, "forged wrong-boot shard0")
    check fileExists(staleAnchor)

    let reaped = reapStaleSegments(dir, "io-mon")
    check reaped >= 1
    check (not fileExists(staleAnchor))   # wrong-boot chain reaped despite live pid

  test "cross-app isolation: a reaper only reaps its OWN appId's segments":
    # THE KEY NEW GUARANTEE. Two DIFFERENT apps (A and B) share one segments
    # directory. A's owner is DEAD (so a NON-scoped reaper WOULD reap it). Assert
    # that B's reaper reaps NOTHING (A is a different appId ⇒ ignored entirely,
    # never even liveness-checked; B itself is live), and that A's reaper reaps
    # A's stale chain but leaves B's alone. Teeth: the pre-appId reaper —
    # `reapStaleSegments(dir)` with no appId — would have reaped A's dead-owner
    # chain here regardless of which app was collecting, corrupting B's peer.
    let dir = freshDir("reapapp")
    defer: removeDir(dir)

    # App B: created and OWNED by this (live) process.
    var bSet = createSet(dir, "appB", "runB", shard0Cap = 32, shard0ArenaCap = 1024)
    check bSet.available
    check bSet.insert(bytesOf("b")) == isInserted

    # App A: a DEAD-owner run — fork a child that creates then exits so its pid dies.
    let child = fork()
    if child == 0:
      var aSet = createSet(dir, "appA", "runA", shard0Cap = 32, shard0ArenaCap = 1024)
      if not aSet.available: quitChild(2)
      discard aSet.insert(bytesOf("a"))
      quitChild(0)                          # leak on purpose; A becomes stale
    var st: cint
    discard waitpid(child, st, 0)

    var aAnchor, bAnchor = ""
    for _, p in walkDir(dir):
      let n = extractFilename(p)
      if not n.endsWith(".shard0"): continue
      if n.startsWith("appA~"): aAnchor = p
      elif n.startsWith("appB~"): bAnchor = p
    check aAnchor.len > 0 and fileExists(aAnchor)
    check bAnchor.len > 0 and fileExists(bAnchor)

    # (1) B's reaper reaps NOTHING: A's dead-owner chain is a DIFFERENT appId and
    # is ignored entirely; B's own chain is live. (Teeth: without appId scoping
    # this would return >=1 and delete A's anchor.)
    check reapStaleSegments(dir, "appB") == 0
    check fileExists(aAnchor)              # A untouched by B's reaper
    check fileExists(bAnchor)             # B (live) untouched

    # (2) A's reaper reaps A's stale chain but leaves B's alone.
    let reapedA = reapStaleSegments(dir, "appA")
    check reapedA >= 1
    check (not fileExists(aAnchor))       # A's stale chain removed
    check fileExists(bAnchor)             # B still untouched
    bSet.detach()
