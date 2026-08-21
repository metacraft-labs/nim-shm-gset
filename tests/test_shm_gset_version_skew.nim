## VERSION-SKEW DIAGNOSTIC suite — a header-layout disagreement must be
## DISTINGUISHABLE, not merely survivable.
##
## NOTHING HERE IS MOCKED. The rev-1 and rev-2 chains are written as genuine
## bytes in their real historical layouts, the skewed producer is a SEPARATE
## PROCESS built from a separate, self-contained implementation of the rev-2
## contract (`tests/helpers/v2_producer.nim` — see its header for why that is a
## peer and not a stand-in), and every attach goes through the real
## `attachSet` / `attachProducer` against real `mmap`ed files.
##
## WHY THIS EXISTS. HM-1 moved the header layout and it broke SILENTLY:
## `headerValid` accepted only the current magic, so a version-skewed producer's
## `attachSet` returned "unavailable", the edge graded `mcIncomplete` by LF-2 and
## the dependency set came back EMPTY with no error anywhere. It degrades in the
## safe direction — never a false cache hit — but invisibly, and it cost an hour
## of a reviewer's time presenting as six unrelated red tests. HM-2 moves the
## layout AGAIN (revision 3, generation-stamped slots), so the same failure
## recurs unless it is made legible.
##
## THE THREE SURFACES, and what each one can and cannot see:
##
##   1. `attachFailure` — PRODUCER-side, precise. A current build that cannot
##      attach now says WHY: `afLayoutSkew` (a genuine shm_gset shard of another
##      revision) is a different answer from `afNotAShard`, `afWrongBoot`,
##      `afKeyDisciplineSkew`, `afMissing` and `afTruncated`. Conservative
##      behaviour is unchanged — the producer is still unavailable and `emit`
##      still returns `emUnavailable`.
##   2. `shardLayoutRevision(path)` — ANY party, from the path alone, using only
##      the frozen magic at offset 0. Turns "empty dep set" into "the chain is
##      revision 2, this build speaks revision 3".
##   3. `producerAttaches` — HOST-side, and the only one that can see the
##      direction that actually bit HM-1. A producer built against an OLDER
##      layout cannot report anything into a file whose shape it does not know,
##      so nothing it does is visible to the host. What IS visible is what it
##      never did: zero successful attaches. `elements == 0 AND attaches == 0`
##      for an action that spawned processes is the fingerprint of a skewed (or
##      un-injected) producer; `elements == 0 AND attaches > 0` means the
##      producers really did attach and really did observe nothing.
##
## HONEST LIMIT, stated because the alternative is to imply a guarantee that does
## not exist: surface 3 is the closest reachable thing to making an OLD build's
## failure visible, not a way of making the old build report. A build that
## predates a diagnostic cannot emit it. Surfaces 1 and 2 are effective from this
## revision forward and in both directions between any two revisions that have
## them.

import std/[os, osproc, posix, streams, strutils, unittest]
import shm_gset
import shm_gset/transport
import ac_index_model

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-skew-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result)
  createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc v2ProducerBin(): string =
  ## The skewed peer, built by the test runner (Justfile `test` / nimble `test`).
  ## A MISSING binary is a hard failure, never a skip: a skew test that quietly
  ## does not run is the same invisibility this suite exists to remove.
  result = getEnv("SHM_GSET_V2_PRODUCER", "tests/helpers/v2_producer")
  doAssert fileExists(result),
    "the rev-2 peer binary is missing at '" & result &
    "'; build it with `nim c -o:tests/helpers/v2_producer " &
    "tests/helpers/v2_producer.nim` (both test runners do this)"


proc runV2Status(args: seq[string]): tuple[output: string; code: int] =
  let p = startProcess(v2ProducerBin(), args = args,
    options = {poStdErrToStdOut, poUsePath})
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (outp, code)

proc writeLegacyV1Shard(path: string; boot, ownerPid: uint64) =
  ## The pre-HM-1 layout as literal bytes: magic revision 1, a 128-byte header,
  ## slots at 128 and no runId field. Spelled out rather than derived from the
  ## `ShOff*` constants, which have moved twice.
  const
    v1HeaderSize = 128
    cap = 64
    arenaCap = 2048
  let slotsOff = v1HeaderSize
  let arenaOff = alignUp(slotsOff + cap * 8, 64)
  let size = alignUp(arenaOff + arenaCap, 4096)
  var buf = newSeq[byte](size)
  proc putU64(buf: var seq[byte]; off: int; v: uint64) =
    var x = v
    copyMem(addr buf[off], addr x, 8)
  proc putU32(buf: var seq[byte]; off: int; v: uint32) =
    var x = v
    copyMem(addr buf[off], addr x, 4)
  buf.putU64(0, ShmGSetMagicV1)
  buf.putU32(8, 1'u32)
  buf.putU32(12, 0'u32)
  buf.putU64(16, boot)
  buf.putU64(24, 0)
  buf.putU64(32, cap)
  buf.putU64(40, uint64(slotsOff))
  buf.putU64(48, uint64(arenaOff))
  buf.putU64(56, arenaCap)
  buf.putU64(64, 8)
  buf.putU64(72, 0)
  buf.putU64(80, 1)
  buf.putU64(88, 0)
  buf.putU64(96, ownerPid)
  buf.putU64(104, boot)
  buf.putU64(112, 1)
  writeFile(path, buf)

# ---------------------------------------------------------------------------
# 1. the peer is REAL: it works against its own layout
# ---------------------------------------------------------------------------

suite "the rev-2 peer is a working producer, not a broken one":

  test "the skewed peer inserts successfully into a rev-2 chain":
    # Without this, every refusal below would be consistent with the peer simply
    # being broken, and the skew assertions would prove nothing.
    let dir = freshDir("peerworks")
    defer: removeDir(dir)
    let path0 = dir / "peer.shard0"
    let (wOut, wCode) = runV2Status(@["write", path0, "peer-run"])
    check wCode == 0
    check fileExists(path0)
    check shardLayoutRevision(path0) == 2       # it really wrote rev 2
    let (pOut, pCode) = runV2Status(@["produce", path0, "hello"])
    check pCode == 0                            # PRIMARY ASSERTION: it WORKS
    check "layout skew" notin pOut
    discard wOut

# ---------------------------------------------------------------------------
# 2. the diagnostic FIRES on a real skew, in both directions
# ---------------------------------------------------------------------------

suite "a header-layout skew is diagnosable":

  test "a skewed producer against a CURRENT chain: refused, and the host can tell":
    # The direction that bit HM-1: an old build, a new chain. The old build can
    # say nothing into a file it does not understand, so what the host observes
    # is an empty dependency set — indistinguishable from "the action touched
    # nothing" until you also look at how many producers ever attached.
    let dir = freshDir("oldnew")
    defer: removeDir(dir)
    var host = startHost(dir, "current-run", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check host.available
    check shardLayoutRevision(host.path0) == int(ShmGSetLayoutRevision)
    check int(ShmGSetLayoutRevision) == 3

    let (outp, code) = runV2Status(@["produce", host.path0, "old-build-dep"])
    check code == 10                            # PRIMARY ASSERTION: it refused
    check "layout skew" in outp                 # ...and named the reason
    check host.snapshot().len == 0              # conservative: nothing landed
    check host.producerAttaches == 0'u64        # PRIMARY ASSERTION: the
                                                # host-visible fingerprint
    check host.growthFailures() == 0

    # CONTRAST — the same host, a CURRENT-build producer. Same empty-set risk,
    # completely different signal: the attach counter separates "skewed peer"
    # from "the action genuinely read nothing".
    var ok = attachProducer(host.path0)
    check ok.available
    check ok.attachFailure == afNone
    check host.producerAttaches == 1'u64        # PRIMARY ASSERTION: the
                                                # contrast that gives it meaning
    check ok.emit(bytesOf("real-dep")) == emInserted
    ok.detach()
    check host.snapshot().len == 1
    host.finish()

  test "a current producer against a rev-2 chain reports afLayoutSkew":
    # The mirror direction, and the one a build can actually report on: this
    # build knows it speaks revision 3 and can see the file says revision 2.
    let dir = freshDir("newold")
    defer: removeDir(dir)
    let path0 = dir / "old.shard0"
    let (_, wCode) = runV2Status(@["write", path0, "old-run"])
    check wCode == 0

    var s = attachSet(path0)
    check (not s.available)                     # conservative, as before
    check s.attachFailure == afLayoutSkew       # PRIMARY ASSERTION
    var p = attachProducer(path0)
    check (not p.available)
    check p.attachFailure == afLayoutSkew       # PRIMARY ASSERTION (transport)
    check p.emit(bytesOf("x")) == emUnavailable # behaviour UNCHANGED
    check shardLayoutRevision(path0) == 2
    check shardLayoutRevision(path0) != int(ShmGSetLayoutRevision)
    p.detach(); s.detach()

  test "a rev-1 chain is layout skew too, and names its revision":
    let dir = freshDir("v1")
    defer: removeDir(dir)
    let path0 = dir / ("oldapp" & $AppIdSep & "1.1.1.shard0")
    writeLegacyV1Shard(path0, bootId(), uint64(getpid()))
    var s = attachSet(path0)
    check (not s.available)
    check s.attachFailure == afLayoutSkew       # PRIMARY ASSERTION
    check shardLayoutRevision(path0) == 1
    s.detach()

# ---------------------------------------------------------------------------
# 3. the diagnostic DISCRIMINATES — a skew is not every other failure
# ---------------------------------------------------------------------------

suite "afLayoutSkew is distinguishable from every other attach failure":

  test "each failure mode reports its OWN reason":
    # The whole value of the diagnostic is discrimination. If every failure said
    # `afLayoutSkew` it would be exactly as useless as every failure saying
    # `unavailable`.
    let dir = freshDir("reasons")
    defer: removeDir(dir)

    # afBadPath — not an anchor name at all.
    check attachSet(dir / "nope.txt").attachFailure == afBadPath

    # afMissing — a well-formed anchor name with no file behind it.
    check attachSet(dir / "gone.shard0").attachFailure == afMissing

    # afTruncated — a file far too small to carry a header.
    let tiny = dir / "tiny.shard0"
    writeFile(tiny, "not a shard")
    check attachSet(tiny).attachFailure == afTruncated

    # afNotAShard — big enough, but never written by this library.
    let junk = dir / "junk.shard0"
    writeFile(junk, repeat('\x00', 8192))
    check attachSet(junk).attachFailure == afNotAShard

    # afKeyDisciplineSkew — the CURRENT layout, another key discipline.
    var keyed = createSetT(dir, "repro", "keyed", AcIndexKey, shard0Cap = 64,
      shard0ArenaCap = 4096)
    check keyed.available
    check attachSet(keyed.path0).attachFailure == afKeyDisciplineSkew
    check shardLayoutRevision(keyed.path0) == int(ShmGSetLayoutRevision)
                                                # same LAYOUT, different policy
    keyed.detach()

    # afWrongBoot — the current layout and the current discipline, but a chain
    # created on another boot. Real bytes from a real chain, with only the
    # creator boot id patched.
    var s = createSet(dir, "io-mon", "stale", shard0Cap = 64,
      shard0ArenaCap = 4096)
    check s.available
    let stalePath = s.path0
    s.detach()
    var data = readFile(stalePath)
    var otherBoot = bootId() + 1
    copyMem(addr data[ShOffCreatorBootId], addr otherBoot, 8)
    writeFile(stalePath, data)
    check attachSet(stalePath).attachFailure == afWrongBoot
    check shardLayoutRevision(stalePath) == int(ShmGSetLayoutRevision)

    # afLayoutSkew — a genuine shard of another revision.
    let old0 = dir / "old.shard0"
    let (_, wCode) = runV2Status(@["write", old0, "old-run"])
    check wCode == 0
    check attachSet(old0).attachFailure == afLayoutSkew   # PRIMARY ASSERTION

  test "producerAttaches is generation-scoped, so a recycled chain starts clean":
    # The host-side fingerprint has to be per-ACTION, or the second action of a
    # recycled chain would inherit the first one's attaches and the "zero
    # attaches" signal would never fire again.
    let dir = freshDir("attachgen")
    defer: removeDir(dir)
    var host = startHost(dir, "run-1", shard0Cap = 64, shard0ArenaCap = 4096)
    check host.available
    var p = attachProducer(host.path0)
    check p.available
    check host.producerAttaches == 1'u64
    p.detach()
    check host.reset("run-2") == rsReset
    check host.producerAttaches == 0'u64        # PRIMARY ASSERTION
    var q = attachProducer(host.path0)
    check q.available
    check host.producerAttaches == 1'u64
    q.detach()
    host.finish()
