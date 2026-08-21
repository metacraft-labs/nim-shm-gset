## REAPER IDENTITY suite — `runId` lives in the shard HEADER, not the file name.
##
## Nothing here is mocked. Every case runs against real shard files in a real
## directory, created by the real `createSet`/`attachSet` (or, for the migration
## case, written out in the real pre-HM-1 on-disk layout — bytes, not a stub),
## with real `fork`ed processes providing the dead owners the staleness rule
## needs. No mock is used and none was needed, so this file carries no mock
## justification under the workspace policy.
##
## WHY THIS EXISTS. Shards used to be named `{appId}~{runId}.{boot}.{pid}.shardN`
## and the reaper recovered the run identity by splitting the stem. A chain that
## is RECYCLED (the reset/pool milestones) keeps its files, so a name-borne runId
## would go stale the moment the chain was handed to the next action — the shards
## would misreport which run produced them. The name now carries only what the
## reaper needs to SCOPE (`appId`) and to judge STALENESS (boot, owner pid), plus
## an opaque `chainSeq` uniquifier that carries no identity at all; `runId` moved
## into shard0's header where a future `reset` can rewrite it in place.
##
## The four properties:
##
##   1. attribution comes from the HEADER — a runId that appears nowhere in any
##      file name is still reported correctly;
##   2. appId scoping SURVIVES the change (regression guard: one app never reaps
##      another's segments, even maximally stale ones);
##   3. both staleness conditions still fire (wrong boot id; dead owner pid);
##   4. MIGRATION — a chain written under the OLD naming and the OLD header
##      layout is still collected. It can no longer be attached, so leaving it
##      behind would leak it forever.

import std/[os, posix, strutils, unittest]
import shm_gset

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-reapid-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result)
  createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc anchorsIn(dir: string): seq[string] =
  for _, p in walkDir(dir):
    if extractFilename(p).endsWith(".shard0"): result.add p

proc runInChild(body: proc () {.closure.}) =
  ## Run `body` in a forked child that then `_exit`s, so the chain it created is
  ## owned by a pid that is DEAD by the time the parent reaps. This is the real
  ## staleness condition, not a simulation of one.
  let child = fork()
  if child == 0:
    body()
    quitChild(0)
  var st: cint
  discard waitpid(child, st, 0)

# ---------------------------------------------------------------------------
# 1. attribution by header
# ---------------------------------------------------------------------------

suite "reaper identity comes from the shard header":

  test "reaper_attributes_by_header_not_filename":
    # The chain's runId is chosen so that NO parse of the file name could
    # produce it: it does not occur in the name at all, and it is shaped like a
    # `{something}.{boot}.{pid}` stem so a name-derived guess that happened to
    # look plausible would still be a different string.
    let dir = freshDir("hdrattr")
    defer: removeDir(dir)
    const wantRun = "attributed.by.header~4242"

    # A live chain first: the header is the single source of truth, readable by
    # the owner AND by a producer that only ever saw `path0`.
    var live = createSet(dir, "hdrapp", wantRun, shard0Cap = 32,
      shard0ArenaCap = 1024)
    check live.available
    check live.runId == wantRun
    var prod = attachSet(live.path0)
    check prod.available
    check prod.runId == wantRun                 # producer reads it from shard0
    check prod.insert(bytesOf("x")) == isInserted
    prod.detach()
    # ...and it is NOWHERE in the name.
    let liveName = extractFilename(live.path0)
    check (wantRun notin liveName)
    check ("attributed" notin liveName)
    live.detach()
    removeFile(live.path0)                      # this one is not under test

    # The chain under test: created by a child, so its owner pid is dead.
    runInChild(proc () =
      var cs = createSet(dir, "hdrapp", wantRun, shard0Cap = 32,
        shard0ArenaCap = 1024)
      if not cs.available: quitChild(2)
      discard cs.insert(bytesOf("y")))          # leak on purpose: it must be reaped

    let found = anchorsIn(dir)
    check found.len == 1
    let anchorName = extractFilename(found[0])
    check (wantRun notin anchorName)            # the name cannot supply it...

    let reaped = reapStaleSegmentsDetailed(dir, "hdrapp")
    check reaped.len == 1
    check reaped[0].runIdFromHeader             # ...the header did
    check reaped[0].runId == wantRun            # PRIMARY ASSERTION
    check reaped[0].anchor == found[0]
    check reaped[0].filesRemoved >= 1
    check (not fileExists(found[0]))

    # Teeth: the name's own components are all different strings, so a reaper
    # that fell back to any of them would have failed the assertion above.
    let stem = anchorName[0 ..< anchorName.len - ".shard0".len]
    let rest = stem[stem.find(AppIdSep) + 1 .. ^1]
    for part in rest.rsplit('.', 2):
      check part != wantRun

  test "a runId longer than the header field is REFUSED, never truncated":
    # A silently shortened identity is a misattribution waiting to happen, so
    # the create fails instead.
    let dir = freshDir("runidcap")
    defer: removeDir(dir)
    let tooLong = repeat('r', RunIdMaxBytes + 1)
    var bad = createSet(dir, "hdrapp", tooLong, shard0Cap = 32,
      shard0ArenaCap = 1024)
    check (not bad.available)
    check anchorsIn(dir).len == 0
    let atLimit = repeat('r', RunIdMaxBytes)
    var ok = createSet(dir, "hdrapp", atLimit, shard0Cap = 32,
      shard0ArenaCap = 1024)
    check ok.available
    check ok.runId == atLimit                   # exactly at the limit, intact
    ok.detach()

  test "two chains of one owner with the SAME runId do not collide on disk":
    # The name no longer gets its uniqueness from the runId, so this is the case
    # that would silently overwrite a live chain if the uniquifier were dropped.
    # An in-process host owning several concurrent actions is exactly this shape.
    let dir = freshDir("twochains")
    defer: removeDir(dir)
    var a = createSet(dir, "hdrapp", "same", shard0Cap = 32, shard0ArenaCap = 1024)
    var b = createSet(dir, "hdrapp", "same", shard0Cap = 32, shard0ArenaCap = 1024)
    check a.available and b.available
    check a.path0 != b.path0
    check a.insert(bytesOf("only-in-a")) == isInserted
    check b.insert(bytesOf("only-in-b")) == isInserted
    check a.contains(bytesOf("only-in-a"))
    check (not a.contains(bytesOf("only-in-b")))    # no cross-attribution
    check (not b.contains(bytesOf("only-in-a")))
    check a.runId == "same" and b.runId == "same"
    a.detach(); b.detach()

# ---------------------------------------------------------------------------
# 2. appId scoping (REGRESSION GUARD on shm_gset.nim's reaper contract)
# ---------------------------------------------------------------------------

suite "the appId scope survives the identity change":

  test "reaper_still_scopes_by_appid":
    # The guarantee: a reaper scoped to its own appId never reaps another app's
    # segments — not even segments that are MAXIMALLY stale (wrong boot id AND a
    # dead owner pid), which is the strongest form of the temptation.
    #
    # The clause "never even liveness-checked" is structural: in
    # `reapStaleSegmentsDetailed` the appId comparison precedes every `pidAlive`
    # call, every `open`/`flock` and every header read, and a foreign anchor
    # `continue`s before any of them. That ordering is not observable from
    # outside the process, so what is asserted here is the observable half: the
    # files survive and the chain is absent from the report.
    let dir = freshDir("scope")
    defer: removeDir(dir)

    # App B: a live chain owned by this process.
    var bSet = createSet(dir, "appB", "runB", shard0Cap = 32, shard0ArenaCap = 1024)
    check bSet.available
    check bSet.insert(bytesOf("b")) == isInserted

    # App A: a dead-owner chain (a child creates it and exits).
    runInChild(proc () =
      var aSet = createSet(dir, "appA", "runA", shard0Cap = 32,
        shard0ArenaCap = 1024)
      if not aSet.available: quitChild(2)
      discard aSet.insert(bytesOf("a")))

    # App C: maximally stale — dead owner AND a boot id that is not this boot.
    # A real chain, renamed onto a wrong-boot stem, so the header is genuine.
    var cAnchorRenamed = ""
    runInChild(proc () =
      var cSet = createSet(dir, "appC", "runC", shard0Cap = 32,
        shard0ArenaCap = 1024)
      if not cSet.available: quitChild(2)
      discard cSet.insert(bytesOf("c")))
    for p in anchorsIn(dir):
      if extractFilename(p).startsWith("appC" & $AppIdSep):
        let dead = shardBasePrefix(dir, "appC", 77'u64, bootId() + 1, 999999'u64)
        cAnchorRenamed = dead & ".shard0"
        moveFile(p, cAnchorRenamed)
    check cAnchorRenamed.len > 0

    var aAnchor = ""
    for p in anchorsIn(dir):
      if extractFilename(p).startsWith("appA" & $AppIdSep): aAnchor = p
    check aAnchor.len > 0

    # B's reaper: A and C are other apps ⇒ ignored entirely; B itself is live.
    let bReport = reapStaleSegmentsDetailed(dir, "appB")
    check bReport.len == 0                       # PRIMARY ASSERTION
    check fileExists(aAnchor)                    # A untouched by B's reaper
    check fileExists(cAnchorRenamed)             # C untouched even so stale
    check fileExists(bSet.path0)                 # B (live) untouched

    # A's reaper takes A's chain and only A's.
    let aReport = reapStaleSegmentsDetailed(dir, "appA")
    check aReport.len == 1
    check aReport[0].runId == "runA"
    check (not fileExists(aAnchor))
    check fileExists(cAnchorRenamed)
    check fileExists(bSet.path0)

    # C's reaper takes C's chain and only C's.
    let cReport = reapStaleSegmentsDetailed(dir, "appC")
    check cReport.len == 1
    check cReport[0].runId == "runC"             # identity survived the RENAME
    check (not fileExists(cAnchorRenamed))
    check fileExists(bSet.path0)
    bSet.detach()

# ---------------------------------------------------------------------------
# 3. both staleness conditions
# ---------------------------------------------------------------------------

suite "staleness still fires on both axes":

  test "reaper_still_reaps_across_boot_and_dead_owner":
    let dir = freshDir("stale")
    defer: removeDir(dir)

    # (a) WRONG BOOT, LIVE pid: a chain that survived a reboot. Real shard files
    # with a real header, renamed onto a stem whose boot id is not this boot and
    # whose owner pid is THIS (running) process — so only the boot mismatch can
    # make it stale.
    var rebooted = createSet(dir, "staleapp", "rebooted-run", shard0Cap = 32,
      shard0ArenaCap = 1024)
    check rebooted.available
    check rebooted.insert(bytesOf("r")) == isInserted
    let rebootedOld = rebooted.path0
    rebooted.detach()
    let wrongBootPrefix = shardBasePrefix(dir, "staleapp", 5'u64, bootId() + 1,
      uint64(getpid()))
    let rebootedAnchor = wrongBootPrefix & ".shard0"
    moveFile(rebootedOld, rebootedAnchor)

    # (b) CURRENT BOOT, DEAD pid: the owner exited.
    runInChild(proc () =
      var cs = createSet(dir, "staleapp", "dead-owner-run", shard0Cap = 32,
        shard0ArenaCap = 1024)
      if not cs.available: quitChild(2)
      discard cs.insert(bytesOf("d")))

    # (c) CURRENT BOOT, LIVE pid: must be left alone.
    var live = createSet(dir, "staleapp", "live-run", shard0Cap = 32,
      shard0ArenaCap = 1024)
    check live.available

    let report = reapStaleSegmentsDetailed(dir, "staleapp")
    var byRun: seq[string]
    for seg in report: byRun.add seg.runId
    check byRun.len == 2                              # PRIMARY ASSERTION
    check "rebooted-run" in byRun                     # boot-id axis fired
    check "dead-owner-run" in byRun                   # dead-owner axis fired
    check ("live-run" notin byRun)                    # live owner spared
    for seg in report:
      check seg.runIdFromHeader
      check seg.filesRemoved >= 1
    check (not fileExists(rebootedAnchor))
    check fileExists(live.path0)
    check live.runId == "live-run"                    # still intact afterwards
    live.detach()

# ---------------------------------------------------------------------------
# 4. migration from the pre-HM-1 naming + header layout
# ---------------------------------------------------------------------------

proc writeLegacyShard(path: string; shardId: int; boot, ownerPid,
    chainCount: uint64) =
  ## Write a shard file in the REAL pre-HM-1 on-disk layout: magic revision 1, a
  ## 128-byte header, slots at offset 128, and NO runId field (the runId lived
  ## in the file name). The offsets are spelled out as literals rather than
  ## taken from the `ShOff*` constants precisely because those constants have
  ## moved — this must keep describing the old layout however the current one
  ## evolves.
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
  buf.putU64(0, ShmGSetMagicV1)          # magic (layout revision 1)
  buf.putU32(8, 1'u32)                   # format version
  buf.putU32(12, 0'u32)                  # flags
  buf.putU64(16, boot)                   # creator boot id
  buf.putU64(24, uint64(shardId))
  buf.putU64(32, cap)
  buf.putU64(40, uint64(slotsOff))
  buf.putU64(48, uint64(arenaOff))
  buf.putU64(56, arenaCap)
  buf.putU64(64, 8)                      # arena used (guard word)
  buf.putU64(72, 0)                      # occupied
  buf.putU64(80, chainCount)
  buf.putU64(88, 0)                      # growth failed
  buf.putU64(96, ownerPid)               # consumer pid
  buf.putU64(104, boot)                  # consumer boot
  buf.putU64(112, 1)                     # consumer alive
  writeFile(path, buf)

proc legacyPrefix(dir, appId, runId: string; boot, ownerPid: uint64): string =
  ## The pre-HM-1 anchor stem, spelled out literally:
  ## `{appId}~{runId}.{boot}.{pid}`. `shardBasePrefix` no longer produces this
  ## shape, which is the whole point of the migration case.
  dir / (appId & $AppIdSep & runId & "." & $boot & "." & $ownerPid)

suite "migration from the pre-HM-1 naming":

  test "legacy_named_chain_is_reaped_never_leaked":
    # A shard set written by the OLD naming AND the old header layout. It can no
    # longer be attached (the layout revision in the magic refuses it), so if the
    # reaper skipped it, it would sit on disk forever — the 61 GiB incident in
    # miniature. The chosen behaviour is therefore: CLEANLY REAPED, by exactly
    # the same staleness rule as a current chain.
    let dir = freshDir("legacy")
    defer: removeDir(dir)
    const legacyRun = "legacy.run.7"          # dots: the old parse had to cope
    let deadPid = 999_999'u64                 # not a live pid on this boot
    let prefix = legacyPrefix(dir, "oldapp", legacyRun, bootId(), deadPid)
    writeLegacyShard(prefix & ".shard0", 0, bootId(), deadPid, 2)
    writeLegacyShard(prefix & ".shard1", 1, bootId(), deadPid, 2)
    check fileExists(prefix & ".shard0")
    check fileExists(prefix & ".shard1")

    # It is genuinely unreadable now — leaking it would be permanent.
    var attached = attachSet(prefix & ".shard0")
    check (not attached.available)

    let report = reapStaleSegmentsDetailed(dir, "oldapp")
    check report.len == 1                          # PRIMARY ASSERTION: not skipped
    check report[0].filesRemoved == 2              # the WHOLE chain, not just shard0
    check (not report[0].runIdFromHeader)          # v1 header carries no runId
    check report[0].runId == legacyRun             # so the old NAME is reported,
                                                   # flagged as not-from-header
    check report[0].ownerPid == deadPid
    check (not fileExists(prefix & ".shard0"))
    check (not fileExists(prefix & ".shard1"))

  test "a legacy chain whose owner is still ALIVE is left alone":
    # The conservative half of the migration rule: an old-version process still
    # running its chain must not have it deleted underneath it. It becomes
    # reapable by the ordinary rule as soon as that owner exits, so it is
    # deferred, never leaked.
    let dir = freshDir("legacylive")
    defer: removeDir(dir)
    let prefix = legacyPrefix(dir, "oldapp", "still-running", bootId(),
      uint64(getpid()))
    writeLegacyShard(prefix & ".shard0", 0, bootId(), uint64(getpid()), 1)
    check reapStaleSegmentsDetailed(dir, "oldapp").len == 0
    check fileExists(prefix & ".shard0")

  test "a legacy chain from another BOOT is reaped like any other":
    let dir = freshDir("legacyboot")
    defer: removeDir(dir)
    let prefix = legacyPrefix(dir, "oldapp", "prev.boot.run", bootId() + 1,
      uint64(getpid()))                            # live pid: only boot is stale
    writeLegacyShard(prefix & ".shard0", 0, bootId() + 1, uint64(getpid()), 1)
    let report = reapStaleSegmentsDetailed(dir, "oldapp")
    check report.len == 1
    check report[0].runId == "prev.boot.run"
    check (not report[0].runIdFromHeader)
    check (not fileExists(prefix & ".shard0"))
