## `nim-shm-set` — a shared-memory, lock-free, grow-only SET (G-Set).
##
## Domain-free (like `nim-shm-queue` Layer 1): the element is an opaque byte
## blob; io-mon (or any consumer) supplies the encoding. This library knows only
## bytes. It is the Candidate-C transport of io-mon-Lossless-Event-Capture: a
## structure that DEDUPLICATES AT THE SOURCE so a probe storm (the same path
## stat'd thousands of times) collapses to *distinct* elements, making
## backpressure moot (re-observing an element is one CAS that finds it present).
##
## MODEL — a state-based (convergent) CRDT: a bounded join-semilattice under
## UNION. Insert is idempotent; nothing is ever deleted; merge is set union and
## therefore order-independent. **Pure membership**: the only shared-memory
## mutation is an idempotent slot-claim (CAS an empty slot to an element-record
## offset). There is NO per-element mutable value and NO atomic value RMW, so the
## lost-update / join-on-a-live-slot race class does not exist.
##
## IMPLEMENTATION — a lock-free open-addressed hash table, **file-backed** (one
## file per shard, `mmap(MAP_SHARED)`; "persists" == "the file exists",
## decoupled from mapping count, surviving producer death and `exec` — the
## cross-OS lifetime of design spec §4.3.2). It is **position-independent**: the
## only things stored in shared memory are OFFSETS (a slot holds the byte offset
## of its element record within the same shard) and COUNTS (the chain length);
## there is NO absolute pointer in shared memory, so the segment maps correctly
## at a different virtual base in every process (design spec §4.5(b)).
##
## GROWTH BY SHARDING, not migration (design spec §4.3.1): when the newest shard
## crosses a load threshold, a producer atomically links a NEW, larger shard file
## onto the chain and inserts continue there. Producers that have not noticed
## keep writing older shards — harmless, because there is no migration to race
## and the single-threaded reader unions ALL shards (design spec §4.3.3). The
## chain/control block lives in the FIRST shard (`shard0`, the well-known name),
## which is never migrated (only appended past). Publish-before-write: a new
## shard file is fully initialised and linked under its final name BEFORE the
## chain-count hint is bumped, so a producer that dies right after linking cannot
## strand data the reader can't discover (the reader also directory-scans).
##
## An INTERN ARENA (append-only bump allocator) holds the variable-length element
## bytes; a slot references its record by offset. No hot-path heap allocation on
## insert (the caller supplies the blob; the record is memcpy'd into the arena).
##
## Deterministic SCHEDULE HOOKS (`shm_set/hooks`, test-only `-d:shmSetScheduleHooks`)
## seam every CAS/publish site so M2 can drive interleavings without a retrofit.
##
## Portability: Linux + macOS (POSIX `mmap` MAP_SHARED). On any other platform
## `shmSetSupported` is false and every op reports unavailable (`supported=false`
## arm), so a caller degrades gracefully.

import ./shm_set/hooks
export hooks.SchedulePoint, hooks.scheduleHooksEnabled
when defined(shmSetScheduleHooks):
  export hooks.setScheduleHook, hooks.ScheduleHook

const shmSetSupported* = defined(linux) or defined(macosx)

func alignUp*(n, a: int): int {.inline.} = (n + a - 1) and not (a - 1)

const
  ShmSetMagic* = 0x5347_4D48_53_00_01'u64  ## "SHM SG" — shm_set shard magic.
  ShmSetFormatVersion* = 1'u32

# --- shard file header (offset-only, base-independent) ----------------------
#
# All 8-byte fields on 8-byte-aligned offsets. shard0 is authoritative for the
# control block (chainCount / growthFailed / consumer-liveness); those fields are
# present but unused in shards > 0.
const
  ShOffMagic* = 0                          # u64 (published LAST on init)
  ShOffFormatVersion* = 8                  # u32
  ShOffFlags* = 12                         # u32
  ShOffCreatorBootId* = 16                 # u64
  ShOffShardId* = 24                       # u64
  ShOffCapacity* = 32                      # u64 (slot count, power of two)
  ShOffSlotsOff* = 40                      # u64 (byte offset of slot array)
  ShOffArenaOff* = 48                      # u64 (byte offset of arena)
  ShOffArenaCap* = 56                      # u64 (arena byte capacity)
  ShOffArenaUsed* = 64                     # u64 (atomic bump; arena-relative)
  ShOffOccupied* = 72                      # u64 (atomic claimed-slot count)
  # control block (shard0 authoritative):
  ShOffChainCount* = 80                    # u64 (atomic; number of shards, >=1)
  ShOffGrowthFailed* = 88                  # u64 (atomic; SIGNALLED saturation)
  ShOffConsumerPid* = 96                   # u64
  ShOffConsumerBoot* = 104                 # u64
  ShOffConsumerAlive* = 112                # u64
  ShardHeaderSize* = 128                   # align64 padding to a cache line

# One slot is a single u64 "entry": 0 == empty; otherwise the absolute byte
# offset (within THIS shard's mapping) of the element's arena record. Published
# by ONE release CAS (empty -> offset), so a reader that acquire-observes a
# non-zero entry also observes the fully-written record it points at.
const SlotSize* = 8

# Arena record: [fp u64][len u32][pad u32][bytes...], 8-aligned. Self-contained,
# so the slot offset is the only reference needed (position-independent).
const
  ArenaRecFp* = 0                          # u64 fingerprint (never 0)
  ArenaRecLen* = 8                         # u32 element byte length
  ArenaRecBytes* = 16                      # element bytes start here
  ArenaRecHdr* = 16

func fingerprint*(blob: openArray[byte]): uint64 =
  ## 64-bit FNV-1a over the element bytes; the low bits pick the home slot and
  ## the full value fast-rejects a probe mismatch before the byte compare.
  result = 1469598103934665603'u64
  for b in blob:
    result = (result xor uint64(b)) * 1099511628211'u64

func shardFileSize*(cap, arenaCap: int): int {.inline.} =
  let slotsOff = ShardHeaderSize
  let arenaOff = alignUp(slotsOff + cap * SlotSize, 64)
  alignUp(arenaOff + arenaCap, 4096)

type
  InsertStatus* = enum
    isInserted    ## a NEW element was published into a slot
    isExists      ## the element was already present (idempotent no-op)
    isSaturated   ## growth itself failed (OOM): SIGNALLED, surfaced by consumer
    isUnavailable ## the set is not attached (portable no-op arm / attach failed)

when shmSetSupported:
  import std/[os, posix, sets, strutils, times]

  # BSD advisory whole-file lock (Linux + macOS share these op values). Used by
  # the reaper to avoid GC'ing a run that is just starting.
  proc flock(fd: cint; op: cint): cint {.importc, header: "<sys/file.h>".}
  const
    LOCK_EX = cint(2)
    LOCK_NB = cint(4)

  type
    ShmBase = ptr UncheckedArray[byte]

    ShardMap = object
      base: ShmBase
      size: int
      fd: cint
      cap: int
      slotsOff: int
      arenaOff: int
      arenaCap: int

    ShmSet* = object
      ## An attached view of a run's shard chain. `available` is false on any
      ## create/attach failure. Multi-producer, single-reader.
      available*: bool
      isConsumer: bool
      dir*: string
      basePrefix: string        ## dir/runId.boot.pid  (shard{K} appended)
      path0*: string            ## shard0 path — the well-known REPRO_MONITOR name
      boot: uint64
      shards: seq[ShardMap]     ## index == shardId; lazily mapped
      tmpCtr: int

  # --- offset-addressed atomics (C11/GCC builtins) --------------------------
  template atField(base: ShmBase; offset: int; T: typedesc): ptr T =
    cast[ptr T](addr base[offset])

  proc loadU64Acquire(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_ACQUIRE)
  proc loadU64Relaxed(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_RELAXED)
  proc storeU64Relaxed(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELAXED)
  proc storeU64Release(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELEASE)
  proc casU64(base: ShmBase; off: int; expected: var uint64;
      desired: uint64): bool {.inline.} =
    atomicCompareExchangeN(atField(base, off, uint64), addr expected, desired,
      false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)
  proc fetchAddU64(base: ShmBase; off: int; d: uint64): uint64 {.inline.} =
    atomicAddFetch(atField(base, off, uint64), d, ATOMIC_SEQ_CST) - d
  proc loadU32Acquire(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_ACQUIRE)
  proc storeU32Relaxed(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELAXED)
  proc storeU32Release(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELEASE)

  proc bootId*(): uint64 =
    ## Per-boot identity (invalidates a stale post-reboot shard). Never zero.
    when defined(linux):
      try:
        let raw = readFile("/proc/sys/kernel/random/boot_id")
        var h: uint64 = 1469598103934665603'u64
        for ch in raw:
          if ch != '-' and ch != '\n':
            h = (h xor uint64(ord(ch))) * 1099511628211'u64
        return (h or 1'u64)
      except CatchableError: discard
    (uint64(getTime().toUnix()) or 1'u64)

  const
    GrowthFactor* = 4       ## per-shard capacity multiplier (§4.3.1: 4–8)
    LoadNum = 1
    LoadDen = 2             ## grow at load factor 0.5 (short probe chains)

  # --- mmap plumbing --------------------------------------------------------

  when defined(shmSetScheduleHooks):
    var forcedNextMapBase {.threadvar.}: pointer
    proc setForcedNextMapBase*(p: pointer) =
      ## TEST-ONLY (design spec §4.5(b)): force the NEXT shard `mmap` to land at a
      ## deliberately chosen base via `MAP_FIXED`, so a test can prove the segment
      ## is position-independent (offsets only, no absolute pointers) even at a
      ## base of the test's choosing. The hint is consumed by one map and cleared.
      forcedNextMapBase = p

  proc mapFd(fd: cint; size: int): ShmBase =
    when defined(shmSetScheduleHooks):
      if forcedNextMapBase != nil:
        let want = forcedNextMapBase
        forcedNextMapBase = nil
        let pf = mmap(want, size, PROT_READ or PROT_WRITE,
          MAP_SHARED or MAP_FIXED, fd, 0)
        if pf == MAP_FAILED: return nil
        return cast[ShmBase](pf)
    let p = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
    if p == MAP_FAILED: return nil
    cast[ShmBase](p)

  proc initShardHeader(base: ShmBase; shardId, cap, arenaCap: int;
      boot: uint64; chainCount: uint64) =
    let slotsOff = ShardHeaderSize
    let arenaOff = alignUp(slotsOff + cap * SlotSize, 64)
    storeU64Relaxed(base, ShOffFlags, 0)
    storeU64Relaxed(base, ShOffCreatorBootId, boot)
    storeU64Relaxed(base, ShOffShardId, uint64(shardId))
    storeU64Relaxed(base, ShOffCapacity, uint64(cap))
    storeU64Relaxed(base, ShOffSlotsOff, uint64(slotsOff))
    storeU64Relaxed(base, ShOffArenaOff, uint64(arenaOff))
    storeU64Relaxed(base, ShOffArenaCap, uint64(arenaCap))
    storeU64Relaxed(base, ShOffArenaUsed, 8)   # skip a guard word so 0==empty
    storeU64Relaxed(base, ShOffOccupied, 0)
    storeU64Relaxed(base, ShOffChainCount, chainCount)
    storeU64Relaxed(base, ShOffGrowthFailed, 0)
    storeU64Relaxed(base, ShOffConsumerPid, 0)
    storeU64Relaxed(base, ShOffConsumerBoot, 0)
    storeU64Relaxed(base, ShOffConsumerAlive, 0)
    storeU32Release(base, ShOffFormatVersion, ShmSetFormatVersion)
    # Publish magic LAST (release): an attacher that sees the magic also sees the
    # fully-initialised header + zeroed slots/arena.
    storeU64Release(base, ShOffMagic, ShmSetMagic)

  proc headerValid(base: ShmBase; boot: uint64): bool =
    loadU64Acquire(base, ShOffMagic) == ShmSetMagic and
      loadU32Acquire(base, ShOffFormatVersion) == ShmSetFormatVersion and
      loadU64Relaxed(base, ShOffCreatorBootId) == boot

  proc mapShardFromFd(fd: cint; size: int; boot: uint64): ShardMap =
    result.fd = -1
    let base = mapFd(fd, size)
    if base.isNil: return
    if not headerValid(base, boot):
      discard munmap(cast[pointer](base), size); return
    result.base = base
    result.size = size
    result.fd = fd
    result.cap = int(loadU64Relaxed(base, ShOffCapacity))
    result.slotsOff = int(loadU64Relaxed(base, ShOffSlotsOff))
    result.arenaOff = int(loadU64Relaxed(base, ShOffArenaOff))
    result.arenaCap = int(loadU64Relaxed(base, ShOffArenaCap))

  proc shardPath(s: ShmSet; k: int): string = s.basePrefix & ".shard" & $k

  proc openShard(s: var ShmSet; k: int): bool =
    ## Map shard `k` into this process (idempotent). Retries briefly to tolerate
    ## the window between a chain-count bump and the file appearing.
    if k < s.shards.len and not s.shards[k].base.isNil: return true
    let path = shardPath(s, k)
    var tries = 0
    while true:
      if fileExists(path):
        var size = 0
        try: size = int(getFileSize(path))
        except CatchableError: return false
        if size <= ShardHeaderSize: return false
        let fd = open(path.cstring, O_RDWR)
        if fd < 0: return false
        let sm = mapShardFromFd(fd, size, s.boot)
        if sm.base.isNil:
          discard close(fd); return false
        if k >= s.shards.len: s.shards.setLen(k + 1)
        s.shards[k] = sm
        return true
      inc tries
      if tries > 10000: return false
      discard sched_yield()

  proc chainCount(s: var ShmSet): int {.inline.} =
    int(loadU64Acquire(s.shards[0].base, ShOffChainCount))

  proc bumpChainCountTo(s: var ShmSet; target: int) =
    let b = s.shards[0].base
    var cur = loadU64Acquire(b, ShOffChainCount)
    while cur < uint64(target):
      scheduleHook(spBeforeChainBump)
      if casU64(b, ShOffChainCount, cur, uint64(target)): break

  # --- element compare over an arena record ---------------------------------

  proc entryMatches(base: ShmBase; entry: uint64; fp: uint64;
      blob: openArray[byte]): bool =
    ## The slot entry was acquire-loaded, so the release-published arena record
    ## it points at is fully visible (torn-key safe).
    let off = int(entry)
    if loadU64Acquire(base, off + ArenaRecFp) != fp: return false
    if int(loadU32Acquire(base, off + ArenaRecLen)) != blob.len: return false
    if blob.len == 0: return true
    return equalMem(addr base[off + ArenaRecBytes], unsafeAddr blob[0], blob.len)

  type InsertShardResult = enum siInserted, siExists, siNeedGrow

  proc insertIntoShard(sm: var ShardMap; blob: openArray[byte];
      fp: uint64): InsertShardResult =
    let base = sm.base
    let cap = sm.cap
    let mask = uint64(cap - 1)
    var idx = int(fp and mask)
    var probes = 0
    while probes < cap:
      let slotOff = sm.slotsOff + idx * SlotSize
      let entry = loadU64Acquire(base, slotOff)
      if entry == 0'u64:
        # Empty slot. Reserve arena, write the record fully, THEN publish via a
        # single release CAS (the sole shared mutation — idempotent slot-claim).
        let recSize = alignUp(ArenaRecHdr + blob.len, 8)
        scheduleHook(spBeforeArenaReserve)
        let aoff = int(fetchAddU64(base, ShOffArenaUsed, uint64(recSize)))
        if aoff + recSize > sm.arenaCap:
          return siNeedGrow          # arena exhausted -> shard, never drop
        let absOff = sm.arenaOff + aoff
        storeU64Relaxed(base, absOff + ArenaRecFp, fp)
        storeU32Relaxed(base, absOff + ArenaRecLen, uint32(blob.len))
        if blob.len > 0:
          copyMem(addr base[absOff + ArenaRecBytes], unsafeAddr blob[0], blob.len)
        scheduleHook(spBeforeArenaPublish)
        var expected = 0'u64
        scheduleHook(spBeforeSlotCas)
        if casU64(base, slotOff, expected, uint64(absOff)):
          scheduleHook(spAfterSlotCas)
          discard fetchAddU64(base, ShOffOccupied, 1)
          return siInserted
        scheduleHook(spAfterSlotCas)
        # Lost the slot to a racer; `expected` now holds the winner's entry. If
        # it is our element, we are a duplicate (our arena bytes are wasted —
        # bounded, reaped with the file). Otherwise probe on.
        if entryMatches(base, expected, fp, blob): return siExists
        idx = (idx + 1) and int(mask); inc probes; continue
      else:
        if entryMatches(base, entry, fp, blob): return siExists
        idx = (idx + 1) and int(mask); inc probes; continue
    siNeedGrow                       # table full -> shard, never drop

  proc shouldGrow(sm: ShardMap): bool {.inline.} =
    let occ = loadU64Relaxed(sm.base, ShOffOccupied)
    occ * uint64(LoadDen) >= uint64(sm.cap * LoadNum)

  # Process-global tmp uniquifier. A per-`ShmSet` counter is NOT enough: two
  # producer THREADS in the same process share `getpid()` and both start their
  # own `tmpCtr` at 1, so they would forge the SAME `.shardtmp.<pid>.1` name and
  # the `O_EXCL` loser's `EEXIST` would be misreported as a growth failure
  # (SIGNALLED saturation) even though growth succeeded. An atomic process-global
  # sequence makes every temp name unique across threads.
  var gShardTmpSeq: uint64

  proc appendShardFile(s: var ShmSet; newIndex, newCap, newArenaCap: int): bool =
    ## Create shard `newIndex` if absent, publishing it fully-initialised under
    ## its final name via an EXCLUSIVE `link` (double-grow arbitration: the loser
    ## gets EEXIST, discards its temp — never a leaked shard file). Returns true
    ## if the final shard file exists afterwards.
    let finalPath = shardPath(s, newIndex)
    if fileExists(finalPath): return true
    let size = shardFileSize(newCap, newArenaCap)
    var tfd = cint(-1)
    var tmp: string
    var attempts = 0
    while true:
      let uniq = atomicAddFetch(addr gShardTmpSeq, 1'u64, ATOMIC_SEQ_CST)
      tmp = s.basePrefix & ".shardtmp." & $getpid() & "." & $uniq
      tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600)
      if tfd >= 0: break
      # A colliding temp NAME (a sibling producer thread in this same process, or
      # a stale leftover from a crashed same-pid run) must NOT be reported as a
      # growth failure — pick a fresh name and retry. Any other error is real.
      if errno != EEXIST: return false
      inc attempts
      if attempts > 4096: return false
    if ftruncate(tfd, Off(size)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return false
    let base = mapFd(tfd, size)
    if base.isNil:
      discard close(tfd); discard unlink(tmp.cstring); return false
    initShardHeader(base, newIndex, newCap, newArenaCap, s.boot, 0)
    discard munmap(cast[pointer](base), size)
    discard close(tfd)
    scheduleHook(spBeforeShardLink)
    let linked = link(tmp.cstring, finalPath.cstring)
    scheduleHook(spAfterShardLink)
    discard unlink(tmp.cstring)       # drop the temp name either way
    if linked == 0: return true
    return fileExists(finalPath)      # a racer created it first (EEXIST)

  proc growNewest(s: var ShmSet; expectedN: int; full: ShardMap): bool =
    ## Append a new, larger shard at index `expectedN` (or observe that someone
    ## else already did). Returns false only when growth itself fails (OOM) —
    ## the SIGNALLED saturation case.
    if chainCount(s) > expectedN: return true    # already grew
    let newCap = full.cap * GrowthFactor
    let newArenaCap = full.arenaCap * GrowthFactor
    if not appendShardFile(s, expectedN, newCap, newArenaCap):
      discard fetchAddU64(s.shards[0].base, ShOffGrowthFailed, 1)
      return false
    bumpChainCountTo(s, expectedN + 1)
    return true

  # --- public API -----------------------------------------------------------

  proc shardBasePrefix*(dir, runId: string; boot, ownerPid: uint64): string =
    ## The chain's base name; `shard{K}` is appended per shard. Encodes the boot
    ## + owner pid so the reaper can judge staleness (design spec §4.3.4).
    dir / (runId & "." & $boot & "." & $ownerPid)

  proc createSet*(dir, runId: string; shard0Cap = 1024;
      shard0ArenaCap = 256 * 1024): ShmSet =
    ## CONSUMER/owner side: create shard0 (the well-known anchor) and register
    ## this process as the live consumer. Pass `path0` to producers via
    ## `REPRO_MONITOR_DEP_SHM`. `shard0Cap` MUST be a power of two.
    result.available = false
    result.isConsumer = true
    result.dir = dir
    result.boot = bootId()
    if shard0Cap <= 0 or (shard0Cap and (shard0Cap - 1)) != 0: return
    result.basePrefix = shardBasePrefix(dir, runId, result.boot,
      uint64(getpid()))
    result.path0 = result.basePrefix & ".shard0"
    try:
      if dir.len > 0: createDir(dir)
    except CatchableError: return
    # Create shard0 via temp + atomic rename (a concurrent attacher never sees a
    # half-initialised file), with chainCount = 1.
    let size = shardFileSize(shard0Cap, shard0ArenaCap)
    inc result.tmpCtr
    let tmp = result.path0 & ".tmp." & $getpid()
    let tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600)
    if tfd < 0: return
    if ftruncate(tfd, Off(size)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return
    let base = mapFd(tfd, size)
    if base.isNil:
      discard close(tfd); discard unlink(tmp.cstring); return
    initShardHeader(base, 0, shard0Cap, shard0ArenaCap, result.boot, 1)
    discard munmap(cast[pointer](base), size)
    discard close(tfd)
    try: moveFile(tmp, result.path0)
    except OSError:
      discard unlink(tmp.cstring); return
    if not openShard(result, 0): return
    # Register consumer liveness (LF-4 / reaper).
    storeU64Relaxed(result.shards[0].base, ShOffConsumerBoot, result.boot)
    storeU64Relaxed(result.shards[0].base, ShOffConsumerPid, uint64(getpid()))
    storeU64Release(result.shards[0].base, ShOffConsumerAlive, 1)
    result.available = true

  proc attachSet*(path0: string): ShmSet =
    ## PRODUCER side: attach to a consumer-created chain via shard0's path.
    ## Returns an unavailable set (LF-2: caller fails fast, never spills) when
    ## the file is missing / wrong / stale (boot guard).
    result.available = false
    result.isConsumer = false
    if not path0.endsWith(".shard0"): return
    result.path0 = path0
    result.basePrefix = path0[0 ..< path0.len - ".shard0".len]
    result.dir = parentDir(path0)
    result.boot = bootId()
    if not openShard(result, 0): return
    result.available = true

  proc detach*(s: var ShmSet) =
    for sm in s.shards.mitems:
      if not sm.base.isNil:
        discard munmap(cast[pointer](sm.base), sm.size)
        sm.base = nil
        if sm.fd > 0: discard close(sm.fd)
    s.shards.setLen(0)
    s.available = false

  proc insert*(s: var ShmSet; blob: openArray[byte]): InsertStatus =
    ## Idempotent multi-producer insert. Re-observing an element is a no-op
    ## (`isExists`) — the structure is bounded by DISTINCT elements, not events,
    ## so backpressure never arises. A full shard/arena GROWS (never drops); only
    ## an OOM growth failure returns `isSaturated` (SIGNALLED, never silent).
    if not s.available: return isUnavailable
    let fp = fingerprint(blob) or 1'u64      # 0 is reserved for "empty"
    while true:
      let n = chainCount(s)
      let newestIdx = n - 1
      if not openShard(s, newestIdx): return isSaturated
      case insertIntoShard(s.shards[newestIdx], blob, fp)
      of siInserted:
        if shouldGrow(s.shards[newestIdx]) and chainCount(s) == n:
          discard growNewest(s, n, s.shards[newestIdx])
        return isInserted
      of siExists:
        return isExists
      of siNeedGrow:
        if not growNewest(s, n, s.shards[newestIdx]):
          return isSaturated
        # loop: retry into the (now) newest shard — never drop.

  proc contains*(s: var ShmSet; blob: openArray[byte]): bool =
    ## Membership across the whole chain (probing, no mutation). For the reader's
    ## authoritative distinct set use `snapshot`.
    if not s.available: return false
    let fp = fingerprint(blob) or 1'u64
    let n = chainCount(s)
    for k in 0 ..< n:
      if not openShard(s, k): continue
      let sm = s.shards[k]
      let mask = uint64(sm.cap - 1)
      var idx = int(fp and mask)
      var probes = 0
      while probes < sm.cap:
        let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
        if entry == 0'u64: break
        if entryMatches(sm.base, entry, fp, blob): return true
        idx = (idx + 1) and int(mask); inc probes
    false

  proc discoverMaxShard(s: var ShmSet): int =
    ## The highest shard index to union: max(chainCount-1, any shard file found
    ## on disk). The directory scan catches a shard whose chain-count bump was
    ## lost to a producer crash (publish-before-write robustness, §4.3.1).
    result = chainCount(s) - 1
    let prefix = extractFilename(s.basePrefix) & ".shard"
    try:
      for _, p in walkDir(s.dir):
        let name = extractFilename(p)
        if name.startsWith(prefix):
          let suffix = name[prefix.len .. ^1]
          try:
            let k = parseInt(suffix)
            if k > result: result = k
          except ValueError: discard
    except CatchableError: discard

  iterator items*(s: var ShmSet): seq[byte] =
    ## SINGLE-THREADED reader: union all shards, deduplicated. This is the source
    ## of truth for the depfile (design spec §4.3.3). Union is the G-Set's
    ## semilattice join, so duplicates across shards and partial/last-shard
    ## writes fold cleanly; ordering is irrelevant (the output is canonicalized).
    if s.available:
      var seen = initHashSet[seq[byte]]()
      let maxK = discoverMaxShard(s)
      for k in 0 .. maxK:
        if not openShard(s, k): continue
        let sm = s.shards[k]
        for idx in 0 ..< sm.cap:
          let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
          if entry == 0'u64: continue
          let off = int(entry)
          let n = int(loadU32Acquire(sm.base, off + ArenaRecLen))
          var elem = newSeq[byte](n)
          if n > 0:
            copyMem(addr elem[0], addr sm.base[off + ArenaRecBytes], n)
          if not seen.containsOrIncl(elem):
            yield elem

  proc snapshot*(s: var ShmSet): seq[seq[byte]] =
    ## Materialise the merged distinct set (convenience over `items`).
    for e in s.items: result.add e

  proc shardCount*(s: var ShmSet): int =
    ## Number of shards linked so far (>= 1). The shard-append metric.
    if not s.available: return 0
    discoverMaxShard(s) + 1

  proc claimedSlots*(s: var ShmSet): uint64 =
    ## Sum of claimed slots across shards. An UPPER bound on distinct elements
    ## (an element inserted before and after a grow is counted in two shards);
    ## the exact distinct count is `snapshot().len`.
    if not s.available: return 0
    let maxK = discoverMaxShard(s)
    for k in 0 .. maxK:
      if openShard(s, k):
        result += loadU64Relaxed(s.shards[k].base, ShOffOccupied)

  proc growthFailures*(s: var ShmSet): uint64 =
    ## SIGNALLED saturation count (OOM growth failures). Nonzero ⇒ the consumer
    ## surfaces `mcIncomplete`; it is NEVER a silent drop.
    if not s.available or s.shards.len == 0: return 0
    loadU64Relaxed(s.shards[0].base, ShOffGrowthFailed)

  proc markConsumerGone*(s: var ShmSet) =
    if s.available and s.shards.len > 0 and not s.shards[0].base.isNil:
      storeU64Release(s.shards[0].base, ShOffConsumerAlive, 0)

  proc consumerAlive*(s: ShmSet): bool =
    ## Whether the host/consumer that owns shard0 is still registered as live
    ## (LF-4). The producer interface (`transport`) surfaces this as
    ## `emConsumerGone` so a monitored process learns to stop writing to an
    ## orphaned segment instead of silently accumulating unread state.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return false
    loadU64Acquire(s.shards[0].base, ShOffConsumerAlive) != 0'u64

  proc assertNoAbsolutePointers*(s: var ShmSet) =
    ## DEBUG (design spec §4.5(b)): assert every stored slot value is an in-shard
    ## OFFSET, never an absolute pointer into the mapping. A leaked absolute
    ## pointer would either fall inside the mapping's address window
    ## `[base, base+size)` or exceed the shard size; either is a
    ## position-independence bug that would fault at a different mmap base.
    let maxK = discoverMaxShard(s)
    for k in 0 .. maxK:
      if not openShard(s, k): continue
      let sm = s.shards[k]
      let lo = cast[uint](sm.base)
      let hi = lo + uint(sm.size)
      for idx in 0 ..< sm.cap:
        let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
        if entry == 0'u64: continue
        doAssert entry < uint64(sm.size),
          "slot entry " & $entry & " is not an in-shard offset (>= size " &
          $sm.size & "): absolute-pointer leak"
        let a = uint(entry)
        doAssert not (a >= lo and a < hi),
          "stored slot value falls inside the mapping window: absolute pointer"
        let rlen = int(loadU32Acquire(sm.base, int(entry) + ArenaRecLen))
        doAssert int(entry) + ArenaRecHdr + rlen <= sm.size,
          "arena record overruns the shard (torn/corrupt offset)"

  proc shards0Base*(s: ShmSet): pointer =
    ## The mapped base address of shard0 in THIS process (for the
    ## position-independence test, which asserts two processes/mappings observe
    ## the same set at DIFFERENT bases — no absolute pointer may live in the
    ## segment). Returns nil if unmapped.
    if s.shards.len > 0: cast[pointer](s.shards[0].base) else: nil

  # --- reaper (cross-restart GC, design spec §4.3.4) ------------------------

  proc pidAlive(pid: uint64): bool =
    if pid == 0: return false
    if kill(Pid(pid), cint(0)) == 0: return true
    errno != ESRCH

  proc reapStaleSegments*(dir: string): int =
    ## Cross-restart GC: remove shard files of runs whose owner is gone. For each
    ## `{runId}.{boot}.{pid}.shard0` anchor, reap the whole chain when
    ## boot != currentBoot (survived a reboot ⇒ pids meaningless) OR the owner
    ## pid is dead on the current boot. A live-owner run is left alone. An
    ## `flock(LOCK_EX|LOCK_NB)` on shard0 guards a run that is just starting.
    ## Returns the number of shard FILES removed.
    result = 0
    let cur = bootId()
    var anchors: seq[string]
    try:
      for _, p in walkDir(dir):
        if extractFilename(p).endsWith(".shard0"): anchors.add p
    except CatchableError: return 0
    for anchor in anchors:
      let name = extractFilename(anchor)
      let stem = name[0 ..< name.len - ".shard0".len]  # runId.boot.pid
      let parts = stem.rsplit('.', 2)                  # [runId, boot, pid]
      if parts.len != 3: continue
      var boot, pid: uint64
      try:
        boot = parseBiggestUInt(parts[1]); pid = parseBiggestUInt(parts[2])
      except ValueError: continue
      let stale = (boot != cur) or (not pidAlive(pid))
      if not stale: continue
      # Guard against reaping a run that is just starting.
      let fd = open(anchor.cstring, O_RDWR)
      if fd >= 0:
        let locked = flock(fd, LOCK_EX or LOCK_NB) == 0
        if not locked:
          discard close(fd); continue     # someone holds it: leave it
      let base = dir / stem                # dir/runId.boot.pid
      var k = 0
      while true:
        let sp = base & ".shard" & $k
        if not fileExists(sp): break
        try: removeFile(sp); inc result
        except CatchableError: discard
        inc k
      if fd >= 0: discard close(fd)

else:
  # --- portable no-op arm ---------------------------------------------------
  type
    ShmSet* = object
      available*: bool
      dir*: string
      path0*: string

  proc bootId*(): uint64 = 1'u64
  proc shardBasePrefix*(dir, runId: string; boot, ownerPid: uint64): string =
    dir & "/" & runId & "." & $boot & "." & $ownerPid
  proc createSet*(dir, runId: string; shard0Cap = 1024;
      shard0ArenaCap = 256 * 1024): ShmSet =
    ShmSet(available: false, dir: dir)
  proc attachSet*(path0: string): ShmSet =
    ShmSet(available: false, path0: path0)
  proc detach*(s: var ShmSet) = discard
  proc insert*(s: var ShmSet; blob: openArray[byte]): InsertStatus = isUnavailable
  proc contains*(s: var ShmSet; blob: openArray[byte]): bool = false
  iterator items*(s: var ShmSet): seq[byte] = discard
  proc snapshot*(s: var ShmSet): seq[seq[byte]] = @[]
  proc shardCount*(s: var ShmSet): int = 0
  proc claimedSlots*(s: var ShmSet): uint64 = 0
  proc growthFailures*(s: var ShmSet): uint64 = 0
  proc markConsumerGone*(s: var ShmSet) = discard
  proc consumerAlive*(s: ShmSet): bool = false
  proc assertNoAbsolutePointers*(s: var ShmSet) = discard
  proc shards0Base*(s: ShmSet): pointer = nil
  proc reapStaleSegments*(dir: string): int = 0
