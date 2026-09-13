## The OS contract `shm_gset/platform` depends on, asserted on every platform.
##
## The library's algorithm is portable and is checked by the rest of this suite.
## What is NOT portable — and what a port lives or dies by — is the handful of
## promises the operating system makes about a shared file mapping. This file
## states them as tests so that they are MEASURED on each platform rather than
## assumed from documentation, and so that the two kernels are held to the same
## list instead of each being described in its own terms.
##
## The sharp one is the durability contract, "PERSISTS == THE FILE EXISTS",
## decoupled from the mapping count (design spec §4.3.2). On POSIX it is free.
## Win32 is widely believed to forbid it outright — "you cannot delete or rename
## over a file while a view of it is mapped" — and that belief is why the port
## was expected to need a weaker guarantee. It is wrong: the restriction belongs
## to the SHARE MODE, not to the mapping, and `FILE_SHARE_DELETE` removes it.
## `a mapped view stays coherent after the name is unlinked` below is the same
## test on both platforms and passes on both, which is what lets the contract be
## met identically rather than reinterpreted.
##
## Run under both runners like every other file here.

import std/[os, strutils, unittest]
import shm_gset
import shm_gset/platform
import ./xproc

var tmpCtr = 0
proc freshDir(tag: string): string = freshTestDir("shmgset-plat", tag, tmpCtr)

const Sz = 65536      # a legal view size on both allocation granularities

proc poke(p: pointer; off: int; v: uint64) =
  cast[ptr uint64](cast[uint](p) + uint(off))[] = v
proc peek(p: pointer; off: int): uint64 =
  cast[ptr uint64](cast[uint](p) + uint(off))[]

proc makeSized(path: string; size: int): ShmFile =
  result = openNewExclusive(path)
  doAssert result.isValid, "openNewExclusive failed for " & path
  doAssert setFileSize(result, size), "setFileSize failed for " & path

# --- child roles ------------------------------------------------------------

proc reportBootId(args: seq[string]) =
  ## Write this process's view of the boot identity to a file. A SEPARATE
  ## process is the whole point: the macOS defect this guards against was two
  ## processes disagreeing about the boot, which no in-process check can see.
  try: writeFile(args[0], $bootId())
  except CatchableError: exitChild(4)
  exitChild(0)

proc holdLock(args: seq[string]) =
  ## Take the exclusive whole-file lock, announce it, and hold it until told to
  ## drop it — the shape the reaper's guard is specified against.
  let f = openReadWrite(args[0])
  if not f.isValid: exitChild(2)
  if not tryLockExclusive(f): exitChild(3)
  try: writeFile(args[1], "held")
  except CatchableError: exitChild(4)
  while not fileExists(args[2]): os.sleep(5)
  unlockExclusive(f)
  closeFile(f)
  exitChild(0)

proc exitImmediately(args: seq[string]) =
  discard args
  exitChild(0)

registerChildRole("reportBootId", reportBootId)
registerChildRole("holdLock", holdLock)
registerChildRole("exitImmediately", exitImmediately)
xprocChildEntry()

# ---------------------------------------------------------------------------

suite "the mapping contract":

  test "a mapped view outlives the descriptor it was made from":
    # This is what lets `openShard` close its descriptor the moment the shard is
    # mapped (commit 360bfc1), so a process holding a long chain mapped does not
    # also hold a descriptor per shard. On Win32 it is the documented promise
    # that the system keeps the file open until the last VIEW is unmapped; the
    # section handle is dropped inside `mapShared` and never stored.
    let dir = freshDir("outlive")
    defer: removeDir(dir)
    let path = dir / "a.bin"
    let f = makeSized(path, Sz)
    let v = mapShared(f, Sz)
    check v != nil
    closeFile(f)                              # descriptor gone, view kept
    poke(v, 0, 0xDEAD_BEEF_1234_5678'u64)
    check peek(v, 0) == 0xDEAD_BEEF_1234_5678'u64
    unmapShared(v, Sz)
    # ...and the bytes really reached the file, not just the page cache view.
    let g = openReadWrite(path)
    check g.isValid
    let v2 = mapShared(g, Sz)
    check v2 != nil
    check peek(v2, 0) == 0xDEAD_BEEF_1234_5678'u64
    unmapShared(v2, Sz)
    closeFile(g)

  test "two independent views of one file are coherent at different bases":
    # The primitive-level statement of position independence (design spec
    # §4.5(b)): the segment may land anywhere, so nothing in it may be an
    # absolute address.
    let dir = freshDir("twoviews")
    defer: removeDir(dir)
    let path = dir / "b.bin"
    let f = makeSized(path, Sz)
    let v1 = mapShared(f, Sz)
    let g = openReadWrite(path)
    let v2 = mapShared(g, Sz)
    check v1 != nil
    check v2 != nil
    check v1 != v2                            # genuinely different bases
    poke(v1, 128, 0xABCD_EF01_2345_6789'u64)
    check peek(v2, 128) == 0xABCD_EF01_2345_6789'u64   # PRIMARY ASSERTION
    poke(v2, 256, 0x1111_2222_3333_4444'u64)
    check peek(v1, 256) == 0x1111_2222_3333_4444'u64   # ...and the other way
    unmapShared(v1, Sz); unmapShared(v2, Sz)
    closeFile(f); closeFile(g)

  test "a mapped view stays coherent after the name is unlinked":
    # THE DURABILITY CONTRACT, and the one the port was expected to have to
    # weaken on Windows. "Persists == the file exists" is decoupled from the
    # mapping count in BOTH directions: dropping the name does not disturb a
    # live mapping, and a live mapping does not pin the name.
    #
    # This is not a formality on Win32 — it is refused outright unless every
    # opener passed `FILE_SHARE_DELETE`, which `shm_gset/platform` therefore
    # does on every open, without exception. `retireShard` and the reaper both
    # depend on it.
    let dir = freshDir("unlinked")
    defer: removeDir(dir)
    let path = dir / "c.bin"
    let f = makeSized(path, Sz)
    let v = mapShared(f, Sz)
    check v != nil
    closeFile(f)
    poke(v, 0, 0x0F0F_0F0F_0F0F_0F0F'u64)

    check unlinkPath(path)                    # PRIMARY ASSERTION: it succeeds
    check (not fileExists(path))              # ...and the name is gone at once

    # TEETH: the view must still READ the old value and still accept a WRITE. A
    # kernel that had torn the mapping down would fault on either, and an
    # assertion that only re-read the first value could pass on a stale page.
    check peek(v, 0) == 0x0F0F_0F0F_0F0F_0F0F'u64      # PRIMARY ASSERTION
    poke(v, 8, 0x7777_8888_9999_AAAA'u64)
    check peek(v, 8) == 0x7777_8888_9999_AAAA'u64      # PRIMARY ASSERTION
    unmapShared(v, Sz)
    check (not fileExists(path))

  test "a file can be unlinked while a DESCRIPTOR for it is still open":
    # THE SEQUENCE THE REAPER ACTUALLY PERFORMS, and the one that makes the
    # share mode load-bearing: `reapStaleSegmentsDetailed` opens shard0, takes
    # the exclusive lock on it, and then unlinks the whole chain INCLUDING that
    # anchor — with its own descriptor still open — before closing it.
    #
    # The case above does NOT cover this and must not be mistaken for it: it
    # closes the descriptor before unlinking, and with no handle open the share
    # mode is irrelevant, so Win32 permits the delete either way. Measured: with
    # `FILE_SHARE_DELETE` removed from `openNewExclusive` the case above still
    # passed and this one fails with the unlink refused. That asymmetry is the
    # whole reason this is a separate test.
    let dir = freshDir("unlink-open")
    defer: removeDir(dir)
    let path = dir / "c2.bin"
    let f = makeSized(path, Sz)               # descriptor STAYS OPEN
    let v = mapShared(f, Sz)
    check v != nil
    poke(v, 0, 0x1234_5678_9ABC_DEF0'u64)
    check tryLockExclusive(f)                 # ...and locked, as the reaper does

    check unlinkPath(path)                    # PRIMARY ASSERTION
    check (not fileExists(path))              # PRIMARY ASSERTION

    # Still coherent through both the view and the descriptor that outlived the
    # name, which is what the reaper relies on to finish its bookkeeping.
    check peek(v, 0) == 0x1234_5678_9ABC_DEF0'u64
    poke(v, 16, 0x0BAD_C0DE_0BAD_C0DE'u64)
    check peek(v, 16) == 0x0BAD_C0DE_0BAD_C0DE'u64
    unmapShared(v, Sz)
    closeFile(f)
    check (not fileExists(path))

  when defined(windows):
    test "shrinking a MAPPED file is the one thing Win32 really refuses":
      # The platform module claims this is the single genuine restriction and
      # that the design cannot reach it, because a shard file is sized exactly
      # once, on a fresh temp file, before it is ever mapped. Pin the claim so
      # that it is a measurement rather than a remembered fact.
      let dir = freshDir("shrink")
      defer: removeDir(dir)
      let path = dir / "d.bin"
      let f = makeSized(path, Sz)
      let v = mapShared(f, Sz)
      check v != nil
      check (not setFileSize(f, Sz div 2))    # PRIMARY ASSERTION: refused
      unmapShared(v, Sz)
      check setFileSize(f, Sz div 2)          # ...and allowed once unmapped
      closeFile(f)

suite "the publish contract":

  test "openNewExclusive refuses a name that already exists, and says why":
    # The arbitration behind the shard temp-name retry loop: a COLLIDING NAME
    # must be retried under a fresh name, and any other error must be a real
    # failure. Conflating the two reports a growth failure — SIGNALLED
    # saturation — for something that merely needed a different name.
    let dir = freshDir("excl")
    defer: removeDir(dir)
    let path = dir / "e.bin"
    let f = makeSized(path, Sz)
    closeFile(f)
    let again = openNewExclusive(path)
    check (not again.isValid)                 # PRIMARY ASSERTION
    check lastOpenFailedBecauseItExists()     # PRIMARY ASSERTION: the reason

  test "linkExclusive publishes under a free name and refuses a taken one":
    # The double-grow arbitration: the winner publishes the new shard under its
    # final name, the loser is told the name is taken and drops its temp. Both
    # outcomes must be distinguishable, and neither may leave a file behind.
    let dir = freshDir("link")
    defer: removeDir(dir)
    let src = dir / "f.tmp"
    let dst = dir / "f.final"
    var f = makeSized(src, Sz)
    let v = mapShared(f, Sz)
    poke(v, 0, 0x5A5A_5A5A_5A5A_5A5A'u64)
    unmapShared(v, Sz)
    closeFile(f)
    check linkExclusive(src, dst)             # PRIMARY ASSERTION: published
    check fileExists(dst)
    unlinkPath(src)                           # the caller drops the temp either way

    # A second producer racing for the same shard index must LOSE, not clobber.
    let src2 = dir / "g.tmp"
    f = makeSized(src2, Sz)
    let v2 = mapShared(f, Sz)
    poke(v2, 0, 0xB6B6_B6B6_B6B6_B6B6'u64)    # a DIFFERENT payload
    unmapShared(v2, Sz)
    closeFile(f)
    check (not linkExclusive(src2, dst))      # PRIMARY ASSERTION: refused
    unlinkPath(src2)

    # TEETH: the winner's bytes are the ones under the published name. An
    # implementation that replaced rather than refused would pass the boolean
    # check above and silently lose the winner's shard.
    let h = openReadWrite(dst)
    check h.isValid
    let v3 = mapShared(h, Sz)
    check peek(v3, 0) == 0x5A5A_5A5A_5A5A_5A5A'u64    # PRIMARY ASSERTION
    unmapShared(v3, Sz)
    closeFile(h)
    check (not fileExists(src2))              # no leaked temp

suite "the exclusion contract":

  test "an exclusive whole-file lock excludes another PROCESS until released":
    # The reaper's guard against collecting a run that is just starting. It is
    # `flock(LOCK_EX|LOCK_NB)` on POSIX and `LockFileEx` on Win32, and the two
    # differ in a way that matters elsewhere (advisory versus mandatory — see
    # `readAnchorRunId`), but the exclusion itself must behave the same.
    let dir = freshDir("lock")
    defer: removeDir(dir)
    let path = dir / "h.bin"
    closeFile(makeSized(path, Sz))
    let heldFile = dir / "held"
    let goFile = dir / "go"

    var kid = startChild("holdLock", path, heldFile, goFile)
    var waited = 0
    while not fileExists(heldFile) and waited < 10_000:
      os.sleep(5); waited += 5
    check fileExists(heldFile)

    let mine = openReadWrite(path)
    check mine.isValid
    check (not tryLockExclusive(mine))        # PRIMARY ASSERTION: excluded

    writeFile(goFile, "go")
    check waitChild(kid) == 0
    check tryLockExclusive(mine)              # PRIMARY ASSERTION: now free
    unlockExclusive(mine)
    closeFile(mine)

  test "processAlive answers for this process, a dead child, and a free pid":
    # The reaper's staleness axis. Getting this wrong is not a small error: an
    # answer of "dead" for everything turns the rule into "collect every chain",
    # which is exactly what an access mask without SYNCHRONIZE produced on the
    # first Win32 attempt here.
    check processAlive(uint64(ownPid()))      # PRIMARY ASSERTION: self is alive
    check (not processAlive(0'u64))           # 0 is never a live process

    var kid = startChild("exitImmediately")
    let kpid = childPid(kid)
    check waitChild(kid) == 0
    var waited = 0
    while processAlive(kpid) and waited < 10_000:
      os.sleep(5); waited += 5
    check (not processAlive(kpid))            # PRIMARY ASSERTION: reaped child

suite "the boot-identity contract":

  test "bootId is the SAME in another process and after an elapsed second":
    # The Darwin defect this guards against, recorded on `bootId`: a wall-clock
    # fallback changes every second, so two processes attaching one second apart
    # disagree about the boot, every attach judges a live chain stale, and the
    # set silently reads EMPTY. The Windows analogue is `GetTickCount64`, which
    # is an uptime — a duration, not an identity — and would fail exactly here.
    #
    # In-process repetition cannot see either bug. A second PROCESS can.
    let dir = freshDir("boot")
    defer: removeDir(dir)
    let mine = bootId()
    check mine != 0'u64

    let f1 = dir / "boot1.txt"
    var k1 = startChild("reportBootId", f1)
    check waitChild(k1) == 0
    check readFile(f1).strip() == $mine       # PRIMARY ASSERTION

    os.sleep(1100)                            # cross a whole-second boundary
    let f2 = dir / "boot2.txt"
    var k2 = startChild("reportBootId", f2)
    check waitChild(k2) == 0
    check readFile(f2).strip() == $mine       # PRIMARY ASSERTION
    check bootId() == mine                    # ...and this process has not moved

suite "the chosen-base contract":

  test "a mapping can be forced to a base the caller picked":
    # §4.5(b) at the primitive level, and the one place the two platforms differ
    # in what they will ACCEPT rather than in what they do: POSIX `MAP_FIXED`
    # needs page alignment, `MapViewOfFileEx` needs the 64 KiB allocation
    # granularity and rejects a merely page-aligned base outright.
    # `shmGSetMapBaseAlignment` is exported so a caller of the test seam can
    # pick a legal address instead of hard-coding a POSIX-legal one.
    check shmGSetMapBaseAlignment > 0
    check (shmGSetMapBaseAlignment and (shmGSetMapBaseAlignment - 1)) == 0
    let dir = freshDir("fixed")
    defer: removeDir(dir)
    let path = dir / "i.bin"
    let f = makeSized(path, Sz)
    let want = reserveMapBase(Sz)
    check want != nil
    check cast[uint](want) mod uint(shmGSetMapBaseAlignment) == 0
    let v = mapShared(f, Sz, want)
    check v == want                           # PRIMARY ASSERTION: landed THERE
    poke(v, 0, 0xCAFE_BABE_DEAD_F00D'u64)
    check peek(v, 0) == 0xCAFE_BABE_DEAD_F00D'u64
    unmapShared(v, Sz)
    closeFile(f)
