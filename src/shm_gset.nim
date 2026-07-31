## `nim-shm-gset` — a shared-memory, lock-free, grow-only SET (G-Set).
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
## ============================================================================
## KEY DISCIPLINE IS A PARAMETER (`ShmGSetT[K]`)
## ============================================================================
##
## The structure separates three projections of one element that used to be
## conflated:
##
## 1. **the bytes stored** — the whole `blob` the caller hands to `insert`; it is
##    memcpy'd verbatim into the arena and handed back verbatim by every reader;
## 2. **the bytes hashed** — the element's PRIMARY KEY, a contiguous sub-range of
##    the element chosen by `primaryKeySpan`. The home slot is
##    `hashKey(primaryKey) and mask`, so **all elements sharing a primary key
##    share a home slot** and, under linear probing with no deletion, occupy one
##    contiguous probe run. `withPrimaryKey` walks exactly that run — the run IS
##    the enumeration; there is no stored chain and no pointer update;
## 3. **the thing compared** — element IDENTITY, decided by `identityFp` (a
##    64-bit fast-reject fingerprint kept in the arena record) plus `identityEq`
##    (the authoritative comparison). Two elements that compare identical are
##    interchangeable, so the slot-claim stays idempotent.
##
## `K` is a phantom type parameter carrying nothing at runtime; the hooks are
## ordinary overloads on `typedesc[K]`, resolved and inlined at instantiation —
## no vtable, no indirect call, no heap, nothing added to shared memory. The
## default policy `IdentityKey` makes all three projections the identity (key ≡
## element), which is io-mon's discipline; `ShmGSet* = ShmGSetT[IdentityKey]`, so
## io-mon's API, probe behaviour and on-disk bytes are unchanged.
##
## A policy may also enlarge the per-chain control block
## (`extraControlWords`) — e.g. for a global generation counter used to order
## tombstones — and MUST override `keyFormatVersion` so a chain written under one
## key discipline is never attached under another (`headerValid` rejects it).
##
## Deterministic SCHEDULE HOOKS (`shm_gset/hooks`, test-only `-d:shmGSetScheduleHooks`)
## seam every CAS/publish site so M2 can drive interleavings without a retrofit.
##
## Portability: Linux + macOS (POSIX `mmap` MAP_SHARED). On any other platform
## `shmGSetSupported` is false and every op reports unavailable (`supported=false`
## arm), so a caller degrades gracefully.

import ./shm_gset/hooks
export hooks.SchedulePoint, hooks.scheduleHooksEnabled
when defined(shmGSetScheduleHooks):
  export hooks.setScheduleHook, hooks.ScheduleHook

const shmGSetSupported* = defined(linux) or defined(macosx)

const AppIdSep* = '~'
  ## Reserved separator between the caller-chosen appId and the rest of an anchor
  ## stem (`{appId}~{runId}.{boot}.{pid}`). An appId MUST NOT contain it (see
  ## `validAppId` / `createSet`), so the reaper recovers the appId unambiguously
  ## by splitting the stem at its FIRST occurrence — correct even when `runId`
  ## itself contains dots or tildes. This is what lets `reapStaleSegments` scope
  ## to ONE app and never touch (or even liveness-check) another app's segments.

func validAppId*(appId: string): bool =
  ## An appId is a filesystem-safe, separator-free tag. Reject empty, the
  ## reserved `~` separator, and the path separator `/` (which would break the
  ## `dir/stem` layout). Dots ARE allowed — the reserved separator makes them
  ## unambiguous.
  appId.len > 0 and AppIdSep notin appId and '/' notin appId

func alignUp*(n, a: int): int {.inline.} = (n + a - 1) and not (a - 1)

const
  ShmGSetMagic* = 0x5347_4D48_53_00_01'u64  ## "SHM SG" — shm_gset shard magic.
  ShmGSetFormatVersion* = 1'u32
    ## Format version of the DEFAULT (`IdentityKey`) key discipline. A policy
    ## with a different discipline must pick its own via `keyFormatVersion`.

# --- shard file header (offset-only, base-independent) ----------------------
#
# All 8-byte fields on 8-byte-aligned offsets. shard0 is authoritative for the
# control block (chainCount / growthFailed / consumer-liveness); those fields are
# present but unused in shards > 0.
const
  ShOffMagic* = 0                          # u64 (published LAST on init)
  ShOffFormatVersion* = 8                  # u32
  ShOffFlags* = 12                         # u32 (atomic; ShFlag* bits)
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
  ShOffExtraControl* = ShardHeaderSize     # policy-declared extra control words
                                           # (u64 each) start here; shard0 is
                                           # authoritative, as for the rest of
                                           # the control block.

const ShFlagDrained* = 1'u32
  ## Header flag: every LIVE element of this shard has been copied forward into a
  ## newer shard, so readers may skip it (§ flattening/retirement). Set by a
  ## flattener with a release CAS AFTER all copies succeed; never cleared.

# One slot is a single u64 "entry": 0 == empty; otherwise the absolute byte
# offset (within THIS shard's mapping) of the element's arena record. Published
# by ONE release CAS (empty -> offset), so a reader that acquire-observes a
# non-zero entry also observes the fully-written record it points at.
const SlotSize* = 8

# Arena record: [fp u64][len u32][pad u32][bytes...], 8-aligned. Self-contained,
# so the slot offset is the only reference needed (position-independent). `fp` is
# the element's IDENTITY fingerprint (`identityFp`), NOT its home-slot hash: it
# exists to fast-reject a probe before the byte compare, so it must discriminate
# elements that share a home slot. Under `IdentityKey` the two coincide, which is
# why io-mon's records are byte-identical to the pre-parameterisation format.
const
  ArenaRecFp* = 0                          # u64 identity fingerprint (never 0)
  ArenaRecLen* = 8                         # u32 element byte length
  ArenaRecBytes* = 16                      # element bytes start here
  ArenaRecHdr* = 16

func fingerprint*(blob: openArray[byte]): uint64 =
  ## 64-bit FNV-1a over the given bytes; the low bits pick the home slot and the
  ## full value fast-rejects a probe mismatch before the byte compare.
  result = 1469598103934665603'u64
  for b in blob:
    result = (result xor uint64(b)) * 1099511628211'u64

# ---------------------------------------------------------------------------
# KEY POLICY — the parameterisation.
# ---------------------------------------------------------------------------

type IdentityKey* = object
  ## The default key discipline: the primary key IS the element and identity IS
  ## byte equality. This is io-mon's discipline and reproduces the structure's
  ## original behaviour exactly (same home slot, same stored fingerprint, same
  ## probe sequence, same on-disk bytes).

proc primaryKeySpan*[K](_: typedesc[K];
    blob: openArray[byte]): tuple[a, b: int] {.inline.} =
  ## Inclusive `[a, b]` sub-range of `blob` holding the PRIMARY KEY — the bytes
  ## the home slot is derived from. Elements sharing a primary key share a home
  ## slot and hence one contiguous probe run (`withPrimaryKey`). An empty span is
  ## expressed as `b < a`.
  ##
  ## Default: the whole element. Override to make the structure a multimap keyed
  ## on a prefix/field of the element.
  (0, blob.len - 1)

proc hashKey*[K](_: typedesc[K]; key: openArray[byte]): uint64 {.inline.} =
  ## Hash of the PRIMARY-KEY bytes. `insert` applies it to
  ## `blob[primaryKeySpan]` and `withPrimaryKey` applies it to the caller's key
  ## bytes — the SAME function over the SAME bytes, so a lookup provably lands on
  ## the home slot an insert used. Never 0.
  fingerprint(key) or 1'u64

proc identityFp*[K](_: typedesc[K]; blob: openArray[byte];
    keyHash: uint64): uint64 {.inline.} =
  ## The 64-bit fast-reject fingerprint stored in the arena record. It must
  ## discriminate elements that SHARE a home slot, so the default hashes the
  ## whole element rather than reusing `keyHash` (which is constant across a
  ## run). `keyHash` is passed in so a policy whose key is the whole element can
  ## return it and hash only once. Never 0.
  fingerprint(blob) or 1'u64

proc identityFp*(_: typedesc[IdentityKey]; blob: openArray[byte];
    keyHash: uint64): uint64 {.inline.} =
  ## Key ≡ element, so the home-slot hash IS the identity fingerprint: one FNV
  ## pass per insert, and the stored record is byte-identical to the format that
  ## predates the parameterisation.
  keyHash

proc identityEq*[K](_: typedesc[K];
    stored, probe: openArray[byte]): bool {.inline.} =
  ## Authoritative identity comparison, reached only after `identityFp` matched.
  ## `stored` is a zero-copy view of the arena record; nothing is allocated.
  ## Default: byte equality. A policy that widens this MUST keep it an
  ## equivalence under which equal elements are interchangeable — the slot-claim
  ## keeps whichever it saw first.
  if stored.len != probe.len: return false
  if stored.len == 0: return true
  equalMem(unsafeAddr stored[0], unsafeAddr probe[0], stored.len)

proc keyFormatVersion*[K](_: typedesc[K]): uint32 {.inline.} =
  ## On-disk format version written into every shard header and required to
  ## match on attach. A policy that changes ANY of `primaryKeySpan`, `hashKey`,
  ## `identityFp`, `identityEq` or `extraControlWords` MUST override this, so a
  ## chain is never read under a different key discipline than it was written.
  ShmGSetFormatVersion

proc extraControlWords*[K](_: typedesc[K]): int {.inline.} =
  ## Number of extra u64 control words reserved in every shard header, right
  ## after the fixed 128-byte block (shard0's are the authoritative ones). They
  ## are opaque atomics the consumer owns — e.g. a global generation counter
  ## that totally orders tombstones against records, or a bypass counter.
  ## Default 0, which keeps the slot array at offset 128 exactly as before.
  0

func slotsOffFor*(extraWords: int): int {.inline.} =
  ## Byte offset of the slot array given a policy's extra control words. With 0
  ## extra words this is `ShardHeaderSize`, i.e. unchanged.
  alignUp(ShardHeaderSize + extraWords * 8, 64)

func shardFileSize*(cap, arenaCap: int; extraWords = 0): int {.inline.} =
  let slotsOff = slotsOffFor(extraWords)
  let arenaOff = alignUp(slotsOff + cap * SlotSize, 64)
  alignUp(arenaOff + arenaCap, 4096)

type
  InsertStatus* = enum
    isInserted    ## a NEW element was published into a slot
    isExists      ## the element was already present (idempotent no-op)
    isSaturated   ## growth itself failed (OOM): SIGNALLED, surfaced by consumer
    isUnavailable ## the set is not attached (portable no-op arm / attach failed)

when shmGSetSupported:
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

    ShmGSetT*[K] = object
      ## An attached view of a run's shard chain, under key discipline `K`
      ## (a phantom parameter: it carries no runtime state and adds nothing to
      ## shared memory). `available` is false on any create/attach failure.
      ## Multi-producer, single-reader.
      available*: bool
      isConsumer: bool
      dir*: string
      basePrefix: string        ## dir/runId.boot.pid  (shard{K} appended)
      path0*: string            ## shard0 path — the well-known REPRO_MONITOR name
      boot: uint64
      shards: seq[ShardMap]     ## index == shardId; lazily mapped
      tmpCtr: int

    ShmGSet* = ShmGSetT[IdentityKey]
      ## The io-mon instantiation: key ≡ element. Same type, same layout, same
      ## API and same on-disk bytes as before the parameterisation.

    ElemView* = object
      ## A zero-copy view of one published element, valid while the shard stays
      ## mapped. Nothing is allocated to produce it — this is what lets the read
      ## path enumerate a probe run without touching the heap.
      data*: ptr UncheckedArray[byte]
      len*: int
      shardIndex*: int
      slotIndex*: int

  template bytes*(v: ElemView): openArray[byte] =
    ## The element's bytes as a zero-copy `openArray`.
    v.data.toOpenArray(0, v.len - 1)

  proc toBytesSeq*(v: ElemView): seq[byte] =
    ## Materialise a view (allocates — for tests and cold paths only).
    ##
    ## Deliberately NOT named `toSeq`: this module is imported unqualified by
    ## consumers (io-mon, reprobuild), and an exported `toSeq` participates in
    ## overload resolution against `std/sequtils.toSeq` at every call site in
    ## those consumers. A `toSeq(someIterator(x))` there then resolves to this
    ## proc and fails with "attempting to call routine", which is a confusing
    ## error a long way from its cause.
    result = newSeq[byte](v.len)
    if v.len > 0: copyMem(addr result[0], v.data, v.len)

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
  proc casU32(base: ShmBase; off: int; expected: var uint32;
      desired: uint32): bool {.inline.} =
    atomicCompareExchangeN(atField(base, off, uint32), addr expected, desired,
      false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)

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

  when defined(shmGSetScheduleHooks):
    var forcedNextMapBase {.threadvar.}: pointer
    proc setForcedNextMapBase*(p: pointer) =
      ## TEST-ONLY (design spec §4.5(b)): force the NEXT shard `mmap` to land at a
      ## deliberately chosen base via `MAP_FIXED`, so a test can prove the segment
      ## is position-independent (offsets only, no absolute pointers) even at a
      ## base of the test's choosing. The hint is consumed by one map and cleared.
      forcedNextMapBase = p

  proc mapFd(fd: cint; size: int): ShmBase =
    when defined(shmGSetScheduleHooks):
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
      boot: uint64; chainCount: uint64; fmtVersion: uint32; extraWords: int) =
    let slotsOff = slotsOffFor(extraWords)
    storeU32Relaxed(base, ShOffFlags, 0)
    storeU64Relaxed(base, ShOffCreatorBootId, boot)
    storeU64Relaxed(base, ShOffShardId, uint64(shardId))
    storeU64Relaxed(base, ShOffCapacity, uint64(cap))
    storeU64Relaxed(base, ShOffSlotsOff, uint64(slotsOff))
    storeU64Relaxed(base, ShOffArenaOff, uint64(alignUp(slotsOff + cap * SlotSize, 64)))
    storeU64Relaxed(base, ShOffArenaCap, uint64(arenaCap))
    storeU64Relaxed(base, ShOffArenaUsed, 8)   # skip a guard word so 0==empty
    storeU64Relaxed(base, ShOffOccupied, 0)
    storeU64Relaxed(base, ShOffChainCount, chainCount)
    storeU64Relaxed(base, ShOffGrowthFailed, 0)
    storeU64Relaxed(base, ShOffConsumerPid, 0)
    storeU64Relaxed(base, ShOffConsumerBoot, 0)
    storeU64Relaxed(base, ShOffConsumerAlive, 0)
    for i in 0 ..< extraWords:
      storeU64Relaxed(base, ShOffExtraControl + i * 8, 0)
    storeU32Release(base, ShOffFormatVersion, fmtVersion)
    # Publish magic LAST (release): an attacher that sees the magic also sees the
    # fully-initialised header + zeroed slots/arena.
    storeU64Release(base, ShOffMagic, ShmGSetMagic)

  proc headerValid(base: ShmBase; boot: uint64; fmtVersion: uint32): bool =
    loadU64Acquire(base, ShOffMagic) == ShmGSetMagic and
      loadU32Acquire(base, ShOffFormatVersion) == fmtVersion and
      loadU64Relaxed(base, ShOffCreatorBootId) == boot

  proc mapShardFromFd(fd: cint; size: int; boot: uint64;
      fmtVersion: uint32): ShardMap =
    result.fd = -1
    let base = mapFd(fd, size)
    if base.isNil: return
    if not headerValid(base, boot, fmtVersion):
      discard munmap(cast[pointer](base), size); return
    result.base = base
    result.size = size
    result.fd = fd
    result.cap = int(loadU64Relaxed(base, ShOffCapacity))
    result.slotsOff = int(loadU64Relaxed(base, ShOffSlotsOff))
    result.arenaOff = int(loadU64Relaxed(base, ShOffArenaOff))
    result.arenaCap = int(loadU64Relaxed(base, ShOffArenaCap))

  proc shardPath[K](s: ShmGSetT[K]; k: int): string =
    s.basePrefix & ".shard" & $k

  proc openShard[K](s: var ShmGSetT[K]; k: int; patient = true): bool =
    ## Map shard `k` into this process (idempotent). On the INSERT path (`patient`)
    ## it retries briefly to tolerate the window between a chain-count bump and
    ## the file appearing. READERS pass `patient = false`: a shard file may be
    ## legitimately absent once a flattener has retired it, and a reader must not
    ## spin on that. For a chain that never retires a shard (io-mon) the two are
    ## indistinguishable — every index below the discovered maximum exists.
    mixin keyFormatVersion
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
        let sm = mapShardFromFd(fd, size, s.boot, keyFormatVersion(K))
        if sm.base.isNil:
          discard close(fd); return false
        if k >= s.shards.len: s.shards.setLen(k + 1)
        s.shards[k] = sm
        return true
      if not patient: return false
      inc tries
      if tries > 10000: return false
      discard sched_yield()

  proc chainCount[K](s: var ShmGSetT[K]): int {.inline.} =
    int(loadU64Acquire(s.shards[0].base, ShOffChainCount))

  proc bumpChainCountTo[K](s: var ShmGSetT[K]; target: int) =
    let b = s.shards[0].base
    var cur = loadU64Acquire(b, ShOffChainCount)
    while cur < uint64(target):
      scheduleHook(spBeforeChainBump)
      if casU64(b, ShOffChainCount, cur, uint64(target)): break

  proc isDrained(sm: ShardMap): bool {.inline.} =
    (loadU32Acquire(sm.base, ShOffFlags) and ShFlagDrained) != 0'u32

  # --- element compare over an arena record ---------------------------------

  proc entryMatches(K: typedesc; base: ShmBase; entry: uint64; ifp: uint64;
      blob: openArray[byte]): bool =
    ## The slot entry was acquire-loaded, so the release-published arena record
    ## it points at is fully visible (torn-key safe). Fast-reject on the stored
    ## IDENTITY fingerprint, then defer to the policy's `identityEq` over a
    ## zero-copy view of the stored bytes.
    mixin identityEq
    let off = int(entry)
    if loadU64Acquire(base, off + ArenaRecFp) != ifp: return false
    let n = int(loadU32Acquire(base, off + ArenaRecLen))
    identityEq(K, base.toOpenArray(off + ArenaRecBytes, off + ArenaRecBytes + n - 1),
      blob)

  type InsertShardResult = enum siInserted, siExists, siNeedGrow

  proc insertIntoShard(K: typedesc; sm: var ShardMap; blob: openArray[byte];
      keyHash, ifp: uint64): InsertShardResult =
    let base = sm.base
    let cap = sm.cap
    let mask = uint64(cap - 1)
    var idx = int(keyHash and mask)   # HOME SLOT: derived from the PRIMARY KEY,
                                      # so every element sharing a primary key
                                      # starts (and therefore lands) in one run.
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
        storeU64Relaxed(base, absOff + ArenaRecFp, ifp)
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
        if entryMatches(K, base, expected, ifp, blob): return siExists
        idx = (idx + 1) and int(mask); inc probes; continue
      else:
        if entryMatches(K, base, entry, ifp, blob): return siExists
        idx = (idx + 1) and int(mask); inc probes; continue
    siNeedGrow                       # table full -> shard, never drop

  proc shouldGrow(sm: ShardMap): bool {.inline.} =
    let occ = loadU64Relaxed(sm.base, ShOffOccupied)
    occ * uint64(LoadDen) >= uint64(sm.cap * LoadNum)

  # Process-global tmp uniquifier. A per-`ShmGSet` counter is NOT enough: two
  # producer THREADS in the same process share `getpid()` and both start their
  # own `tmpCtr` at 1, so they would forge the SAME `.shardtmp.<pid>.1` name and
  # the `O_EXCL` loser's `EEXIST` would be misreported as a growth failure
  # (SIGNALLED saturation) even though growth succeeded. An atomic process-global
  # sequence makes every temp name unique across threads.
  var gShardTmpSeq: uint64

  proc appendShardFile[K](s: var ShmGSetT[K]; newIndex, newCap,
      newArenaCap: int): bool =
    ## Create shard `newIndex` if absent, publishing it fully-initialised under
    ## its final name via an EXCLUSIVE `link` (double-grow arbitration: the loser
    ## gets EEXIST, discards its temp — never a leaked shard file). Returns true
    ## if the final shard file exists afterwards.
    mixin keyFormatVersion, extraControlWords
    let finalPath = shardPath(s, newIndex)
    if fileExists(finalPath): return true
    let extraWords = extraControlWords(K)
    let size = shardFileSize(newCap, newArenaCap, extraWords)
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
    initShardHeader(base, newIndex, newCap, newArenaCap, s.boot, 0,
      keyFormatVersion(K), extraWords)
    discard munmap(cast[pointer](base), size)
    discard close(tfd)
    scheduleHook(spBeforeShardLink)
    let linked = link(tmp.cstring, finalPath.cstring)
    scheduleHook(spAfterShardLink)
    discard unlink(tmp.cstring)       # drop the temp name either way
    if linked == 0: return true
    return fileExists(finalPath)      # a racer created it first (EEXIST)

  proc growNewest[K](s: var ShmGSetT[K]; expectedN: int; full: ShardMap): bool =
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

  proc shardBasePrefix*(dir, appId, runId: string; boot, ownerPid: uint64): string =
    ## The chain's base name; `shard{K}` is appended per shard. Encodes the
    ## appId + runId + boot + owner pid as `dir/{appId}~{runId}.{boot}.{pid}`.
    ## The `appId` scopes the reaper (one app never reaps another's segments);
    ## boot + owner pid let it judge staleness (design spec §4.3.4). The reserved
    ## `~` keeps the appId recoverable even if runId contains dots.
    dir / (appId & AppIdSep & runId & "." & $boot & "." & $ownerPid)

  proc createSetT*[K](dir, appId, runId: string; keyPolicy: typedesc[K];
      shard0Cap = 1024; shard0ArenaCap = 256 * 1024): ShmGSetT[K] =
    ## CONSUMER/owner side: create shard0 (the well-known anchor) under key
    ## discipline `K` and register this process as the live consumer. Pass
    ## `path0` to producers via `REPRO_MONITOR_DEP_SHM`. `appId` tags the chain
    ## so only THIS app's reaper considers it (see `reapStaleSegments`); it must
    ## satisfy `validAppId`. `shard0Cap` MUST be a power of two.
    mixin keyFormatVersion, extraControlWords
    result.available = false
    result.isConsumer = true
    result.dir = dir
    result.boot = bootId()
    if not validAppId(appId): return
    if shard0Cap <= 0 or (shard0Cap and (shard0Cap - 1)) != 0: return
    result.basePrefix = shardBasePrefix(dir, appId, runId, result.boot,
      uint64(getpid()))
    result.path0 = result.basePrefix & ".shard0"
    try:
      if dir.len > 0: createDir(dir)
    except CatchableError: return
    # Create shard0 via temp + atomic rename (a concurrent attacher never sees a
    # half-initialised file), with chainCount = 1.
    let extraWords = extraControlWords(K)
    let size = shardFileSize(shard0Cap, shard0ArenaCap, extraWords)
    inc result.tmpCtr
    let tmp = result.path0 & ".tmp." & $getpid()
    let tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600)
    if tfd < 0: return
    if ftruncate(tfd, Off(size)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return
    let base = mapFd(tfd, size)
    if base.isNil:
      discard close(tfd); discard unlink(tmp.cstring); return
    initShardHeader(base, 0, shard0Cap, shard0ArenaCap, result.boot, 1,
      keyFormatVersion(K), extraWords)
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

  proc createSet*(dir, appId, runId: string; shard0Cap = 1024;
      shard0ArenaCap = 256 * 1024): ShmGSet =
    ## `createSetT` at the default key discipline (key ≡ element) — io-mon's
    ## entry point, unchanged.
    createSetT(dir, appId, runId, IdentityKey, shard0Cap, shard0ArenaCap)

  proc attachSetT*[K](path0: string; keyPolicy: typedesc[K]): ShmGSetT[K] =
    ## PRODUCER side: attach to a consumer-created chain via shard0's path.
    ## Returns an unavailable set (LF-2: caller fails fast, never spills) when
    ## the file is missing / wrong / stale (boot guard) — or when the chain was
    ## written under a DIFFERENT key discipline (`keyFormatVersion` mismatch).
    result.available = false
    result.isConsumer = false
    if not path0.endsWith(".shard0"): return
    result.path0 = path0
    result.basePrefix = path0[0 ..< path0.len - ".shard0".len]
    result.dir = parentDir(path0)
    result.boot = bootId()
    if not openShard(result, 0): return
    result.available = true

  proc attachSet*(path0: string): ShmGSet =
    ## `attachSetT` at the default key discipline — io-mon's entry point,
    ## unchanged.
    attachSetT(path0, IdentityKey)

  proc detach*[K](s: var ShmGSetT[K]) =
    for sm in s.shards.mitems:
      if not sm.base.isNil:
        discard munmap(cast[pointer](sm.base), sm.size)
        sm.base = nil
        if sm.fd > 0: discard close(sm.fd)
    s.shards.setLen(0)
    s.available = false

  proc elementKeyHash*[K](s: ShmGSetT[K]; blob: openArray[byte]): uint64 =
    ## The primary-key hash the structure would use to place `blob`. Exposed so a
    ## consumer (and the property suite) can assert coherence between an
    ## element's placement and a key lookup.
    mixin primaryKeySpan, hashKey
    let span = primaryKeySpan(K, blob)
    hashKey(K, blob.toOpenArray(span.a, span.b))

  proc insert*[K](s: var ShmGSetT[K]; blob: openArray[byte]): InsertStatus =
    ## Idempotent multi-producer insert. Re-observing an element is a no-op
    ## (`isExists`) — the structure is bounded by DISTINCT elements, not events,
    ## so backpressure never arises. A full shard/arena GROWS (never drops); only
    ## an OOM growth failure returns `isSaturated` (SIGNALLED, never silent).
    ##
    ## Placement is by PRIMARY KEY (`primaryKeySpan` + `hashKey`); dedup is by
    ## IDENTITY (`identityFp` + `identityEq`). No heap allocation on this path.
    ##
    ## The probe is confined to the NEWEST shard: an element already present in
    ## an older shard may be claimed again here, which is the harmless cross-shard
    ## duplicate the union folds. A consumer that wants the chain-wide
    ## "already present?" answer (e.g. to skip an insert entirely) reads it with
    ## `withPrimaryKey` first — a pure read over mapped memory.
    mixin primaryKeySpan, hashKey, identityFp
    if not s.available: return isUnavailable
    let span = primaryKeySpan(K, blob)
    let keyHash = hashKey(K, blob.toOpenArray(span.a, span.b))
    let ifp = identityFp(K, blob, keyHash)
    while true:
      let n = chainCount(s)
      let newestIdx = n - 1
      if not openShard(s, newestIdx): return isSaturated
      case insertIntoShard(K, s.shards[newestIdx], blob, keyHash, ifp)
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

  proc contains*[K](s: var ShmGSetT[K]; blob: openArray[byte]): bool =
    ## Identity membership across the whole chain (probing, no mutation). For the
    ## reader's authoritative distinct set use `snapshot`; to enumerate everything
    ## sharing `blob`'s primary key use `withPrimaryKey`.
    mixin primaryKeySpan, hashKey, identityFp
    if not s.available: return false
    let span = primaryKeySpan(K, blob)
    let keyHash = hashKey(K, blob.toOpenArray(span.a, span.b))
    let ifp = identityFp(K, blob, keyHash)
    # Bound re-read per step, not snapshotted — see `withPrimaryKeyHash`.
    var k = 0
    while k < chainCount(s):
      if not openShard(s, k, patient = false):
        inc k; continue
      let sm = s.shards[k]
      if sm.isDrained:
        inc k; continue
      let mask = uint64(sm.cap - 1)
      var idx = int(keyHash and mask)
      var probes = 0
      while probes < sm.cap:
        let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
        if entry == 0'u64: break
        if entryMatches(K, sm.base, entry, ifp, blob): return true
        idx = (idx + 1) and int(mask); inc probes
      inc k
    false

  # --- prefix (probe-run) enumeration ---------------------------------------

  iterator withPrimaryKeyHash*[K](s: var ShmGSetT[K];
      keyHash: uint64): ElemView =
    ## Walk the probe run of `keyHash` — from its home slot to the first EMPTY
    ## slot — in every shard of the chain, OLDEST shard first, yielding a
    ## zero-copy view of every element found (INCLUDING foreign keys that hash
    ## into the same run: the caller filters, one comparison each). No stored
    ## chain, no chain-length counter, no pointer update: the run IS the
    ## enumeration. Nothing is ever deleted, so a run is never punctured and the
    ## walk can neither terminate early nor miss a present element.
    ##
    ## Completeness across the chain: an element only ever lands in shard
    ## `chainCount-1` as observed by its inserter, and `chainCount` is monotone
    ## in shard0, so `0 ..< chainCount` covers every element-bearing shard. This
    ## walk therefore performs NO syscall once the shards are mapped.
    ##
    ## OLDEST-FIRST IS LOAD-BEARING under flattening: a flattener copies a
    ## shard's live elements FORWARD and only then marks the source drained, so a
    ## reader that visits the source before the destination sees the elements in
    ## one place or the other (or both), never in neither.
    if s.available:
      # The bound is re-read each step, NOT snapshotted at entry. A flatten
      # migrates elements into the newest shard, which is exactly what makes the
      # chain grow; if the walk fixed its bound at entry it would never visit a
      # shard created mid-walk, while still skipping the drained source those
      # elements came from — losing an element that was observable when the walk
      # began and is still in the set. `chainCount` is monotone and each shard is
      # four times the last, so re-reading terminates.
      var k = 0
      while k < chainCount(s):
        if not openShard(s, k, patient = false):
          inc k; continue
        let sm = s.shards[k]
        if sm.isDrained:
          inc k; continue
        let mask = uint64(sm.cap - 1)
        var idx = int(keyHash and mask)
        var probes = 0
        while probes < sm.cap:
          let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
          if entry == 0'u64: break            # end of the run
          let off = int(entry)
          yield ElemView(
            data: cast[ptr UncheckedArray[byte]](addr sm.base[off + ArenaRecBytes]),
            len: int(loadU32Acquire(sm.base, off + ArenaRecLen)),
            shardIndex: k, slotIndex: idx)
          idx = (idx + 1) and int(mask); inc probes
        inc k

  iterator withPrimaryKey*[K](s: var ShmGSetT[K]; key: openArray[byte]): ElemView =
    ## `withPrimaryKeyHash` over `hashKey(key)` — the SAME hash function, applied
    ## to the SAME bytes an insert hashes (`blob[primaryKeySpan]`), so a lookup
    ## provably starts at the home slot the insert used.
    mixin hashKey
    for v in withPrimaryKeyHash(s, hashKey(K, key)): yield v

  iterator shardElements*[K](s: var ShmGSetT[K]; k: int): ElemView =
    ## Every published element of ONE shard, in slot order (what a flattener
    ## walks). Yields nothing for an unmapped/retired shard.
    if s.available and openShard(s, k, patient = false):
      let sm = s.shards[k]
      for idx in 0 ..< sm.cap:
        let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
        if entry == 0'u64: continue
        let off = int(entry)
        yield ElemView(
          data: cast[ptr UncheckedArray[byte]](addr sm.base[off + ArenaRecBytes]),
          len: int(loadU32Acquire(sm.base, off + ArenaRecLen)),
          shardIndex: k, slotIndex: idx)

  # --- policy-owned control words -------------------------------------------

  proc controlWord*[K](s: var ShmGSetT[K]; i: int): uint64 =
    ## Acquire-read extra control word `i` from shard0's control block.
    mixin extraControlWords
    doAssert i >= 0 and i < extraControlWords(K), "control word out of range"
    if not s.available or s.shards.len == 0: return 0
    loadU64Acquire(s.shards[0].base, ShOffExtraControl + i * 8)

  proc controlWordFetchAdd*[K](s: var ShmGSetT[K]; i: int; d: uint64): uint64 =
    ## Atomically add `d` to extra control word `i`; returns the PREVIOUS value.
    ## (A generation counter allocates with `controlWordFetchAdd(i, 1) + 1`.)
    mixin extraControlWords
    doAssert i >= 0 and i < extraControlWords(K), "control word out of range"
    if not s.available or s.shards.len == 0: return 0
    fetchAddU64(s.shards[0].base, ShOffExtraControl + i * 8, d)

  proc controlWordBumpTo*[K](s: var ShmGSetT[K]; i: int; target: uint64): uint64 =
    ## Monotonically raise extra control word `i` to at least `target` with a CAS
    ## loop; returns the value afterwards. This is how a supersession publishes a
    ## generation it computed from an observed tombstone without ever lowering
    ## the counter.
    mixin extraControlWords
    doAssert i >= 0 and i < extraControlWords(K), "control word out of range"
    if not s.available or s.shards.len == 0: return 0
    let b = s.shards[0].base
    let off = ShOffExtraControl + i * 8
    var cur = loadU64Acquire(b, off)
    while cur < target:
      if casU64(b, off, cur, target): return target
    max(cur, target)

  proc discoverMaxShard[K](s: var ShmGSetT[K]): int =
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

  iterator items*[K](s: var ShmGSetT[K]): seq[byte] =
    ## SINGLE-THREADED reader: union all shards, deduplicated. This is the source
    ## of truth for the depfile (design spec §4.3.3). Union is the G-Set's
    ## semilattice join, so duplicates across shards and partial/last-shard
    ## writes fold cleanly; ordering is irrelevant (the output is canonicalized).
    ## Shards are visited oldest-first, and a drained shard is skipped — see
    ## `withPrimaryKeyHash` for why that order is the safe one under flattening.
    if s.available:
      var seen = initHashSet[seq[byte]]()
      let maxK = discoverMaxShard(s)
      for k in 0 .. maxK:
        if not openShard(s, k, patient = false): continue
        let sm = s.shards[k]
        if sm.isDrained: continue
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

  proc snapshot*[K](s: var ShmGSetT[K]): seq[seq[byte]] =
    ## Materialise the merged distinct set (convenience over `items`).
    for e in s.items: result.add e

  proc shardCount*[K](s: var ShmGSetT[K]): int =
    ## Number of shards linked so far (>= 1). The shard-append metric.
    if not s.available: return 0
    discoverMaxShard(s) + 1

  proc claimedSlots*[K](s: var ShmGSetT[K]): uint64 =
    ## Sum of claimed slots across shards. An UPPER bound on distinct elements
    ## (an element inserted before and after a grow is counted in two shards);
    ## the exact distinct count is `snapshot().len`.
    if not s.available: return 0
    let maxK = discoverMaxShard(s)
    for k in 0 .. maxK:
      if openShard(s, k, patient = false):
        result += loadU64Relaxed(s.shards[k].base, ShOffOccupied)

  proc growthFailures*[K](s: var ShmGSetT[K]): uint64 =
    ## SIGNALLED saturation count (OOM growth failures). Nonzero ⇒ the consumer
    ## surfaces `mcIncomplete`; it is NEVER a silent drop.
    if not s.available or s.shards.len == 0: return 0
    loadU64Relaxed(s.shards[0].base, ShOffGrowthFailed)

  proc markConsumerGone*[K](s: var ShmGSetT[K]) =
    if s.available and s.shards.len > 0 and not s.shards[0].base.isNil:
      storeU64Release(s.shards[0].base, ShOffConsumerAlive, 0)

  proc consumerAlive*[K](s: ShmGSetT[K]): bool =
    ## Whether the host/consumer that owns shard0 is still registered as live
    ## (LF-4). The producer interface (`transport`) surfaces this as
    ## `emConsumerGone` so a monitored process learns to stop writing to an
    ## orphaned segment instead of silently accumulating unread state.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return false
    loadU64Acquire(s.shards[0].base, ShOffConsumerAlive) != 0'u64

  # --- flatten / retire ------------------------------------------------------

  proc shardIsDrained*[K](s: var ShmGSetT[K]; k: int): bool =
    ## Whether shard `k` has been flattened forward and may be skipped. A missing
    ## (already retired) shard counts as drained.
    if not s.available: return false
    if not openShard(s, k, patient = false): return true
    s.shards[k].isDrained

  proc markShardDrained*[K](s: var ShmGSetT[K]; k: int): bool {.discardable.} =
    ## Publish "every live element of shard `k` now also lives in a newer shard".
    ## MUST be called only after those copies have succeeded: the flag is what
    ## permits readers to skip the shard. Never cleared. shard0 is never drained
    ## (it carries the control block).
    if not s.available or k <= 0: return false
    if not openShard(s, k, patient = false): return false
    let b = s.shards[k].base
    var cur = loadU32Acquire(b, ShOffFlags)
    while (cur and ShFlagDrained) == 0'u32:
      if casU32(b, ShOffFlags, cur, cur or ShFlagDrained): return true
    true

  proc retireShard*[K](s: var ShmGSetT[K]; k: int): bool {.discardable.} =
    ## Unlink a DRAINED shard's file. A process that already mapped it keeps a
    ## valid mapping (POSIX inode refcounting) whose content is a subset of a
    ## newer shard, so continuing to read it is harmless — no RCU grace period
    ## and no reader-epoch table is needed. Refuses shard0 and a non-drained
    ## shard. Idempotent: retiring an already-retired shard succeeds.
    ##
    ## The drained flag is read from the shard's OWN header here rather than via
    ## `shardIsDrained`. That predicate answers "may a reader skip this?", for
    ## which treating an unopenable shard as skippable is right. Unlinking is
    ## irreversible and needs the opposite default: `openShard` returns false for
    ## a missing file, a truncated file, an `open` failure, and a mapping or
    ## key-format-version mismatch alike, so a shard that merely could not be
    ## MAPPED must never be mistaken for one that was drained. Only a header we
    ## actually read may authorise the unlink.
    if not s.available or k <= 0: return false
    let path = shardPath(s, k)
    if not fileExists(path): return true      # already retired
    if not openShard(s, k, patient = false): return false
    if not s.shards[k].isDrained: return false
    try:
      removeFile(path)
      true
    except CatchableError:
      false

  proc assertNoAbsolutePointers*[K](s: var ShmGSetT[K]) =
    ## DEBUG (design spec §4.5(b)): assert every stored slot value is an in-shard
    ## OFFSET, never an absolute pointer into the mapping. A leaked absolute
    ## pointer would either fall inside the mapping's address window
    ## `[base, base+size)` or exceed the shard size; either is a
    ## position-independence bug that would fault at a different mmap base.
    let maxK = discoverMaxShard(s)
    for k in 0 .. maxK:
      if not openShard(s, k, patient = false): continue
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

  proc shards0Base*[K](s: ShmGSetT[K]): pointer =
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

  proc reapStaleSegments*(dir, appId: string): int =
    ## Cross-restart GC SCOPED TO ONE appId. Only anchors tagged with `appId`
    ## (`{appId}~{runId}.{boot}.{pid}.shard0`) are considered; segments of any
    ## OTHER appId are IGNORED entirely — never reaped, never even
    ## liveness-checked — so one app cannot reap another's live/crashed segments
    ## and cross-app pid reuse can no longer misfire. WITHIN the matching appId
    ## the staleness rule is unchanged: reap the whole chain when boot !=
    ## currentBoot (survived a reboot ⇒ pids meaningless) OR the owner pid is
    ## dead on the current boot. A live-owner run is left alone. An
    ## `flock(LOCK_EX|LOCK_NB)` on shard0 guards a run that is just starting.
    ## Returns the number of shard FILES removed.
    ##
    ## Key-discipline agnostic: staleness is judged from the anchor NAME and the
    ## owner's liveness, never from the element encoding.
    result = 0
    if not validAppId(appId): return 0
    let cur = bootId()
    var anchors: seq[string]
    try:
      for _, p in walkDir(dir):
        if extractFilename(p).endsWith(".shard0"): anchors.add p
    except CatchableError: return 0
    for anchor in anchors:
      let name = extractFilename(anchor)
      let stem = name[0 ..< name.len - ".shard0".len]  # appId~runId.boot.pid
      let sep = stem.find(AppIdSep)                    # first '~' ends the appId
      if sep < 0: continue                             # untagged / foreign anchor
      if stem[0 ..< sep] != appId: continue            # another app: leave alone
      let rest = stem[sep + 1 .. ^1]                   # runId.boot.pid
      let parts = rest.rsplit('.', 2)                  # [runId, boot, pid]
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
    ShmGSetT*[K] = object
      available*: bool
      dir*: string
      path0*: string
    ShmGSet* = ShmGSetT[IdentityKey]
    ElemView* = object
      data*: ptr UncheckedArray[byte]
      len*: int
      shardIndex*: int
      slotIndex*: int

  template bytes*(v: ElemView): openArray[byte] =
    v.data.toOpenArray(0, v.len - 1)
  proc toBytesSeq*(v: ElemView): seq[byte] = @[]

  proc bootId*(): uint64 = 1'u64
  proc shardBasePrefix*(dir, appId, runId: string; boot, ownerPid: uint64): string =
    dir & "/" & appId & "~" & runId & "." & $boot & "." & $ownerPid
  proc createSetT*[K](dir, appId, runId: string; keyPolicy: typedesc[K];
      shard0Cap = 1024; shard0ArenaCap = 256 * 1024): ShmGSetT[K] =
    ShmGSetT[K](available: false, dir: dir)
  proc createSet*(dir, appId, runId: string; shard0Cap = 1024;
      shard0ArenaCap = 256 * 1024): ShmGSet =
    ShmGSet(available: false, dir: dir)
  proc attachSetT*[K](path0: string; keyPolicy: typedesc[K]): ShmGSetT[K] =
    ShmGSetT[K](available: false, path0: path0)
  proc attachSet*(path0: string): ShmGSet =
    ShmGSet(available: false, path0: path0)
  proc detach*[K](s: var ShmGSetT[K]) = discard
  proc elementKeyHash*[K](s: ShmGSetT[K]; blob: openArray[byte]): uint64 = 0
  proc insert*[K](s: var ShmGSetT[K]; blob: openArray[byte]): InsertStatus =
    isUnavailable
  proc contains*[K](s: var ShmGSetT[K]; blob: openArray[byte]): bool = false
  iterator withPrimaryKeyHash*[K](s: var ShmGSetT[K]; keyHash: uint64): ElemView =
    discard
  iterator withPrimaryKey*[K](s: var ShmGSetT[K];
      key: openArray[byte]): ElemView = discard
  iterator shardElements*[K](s: var ShmGSetT[K]; k: int): ElemView = discard
  proc controlWord*[K](s: var ShmGSetT[K]; i: int): uint64 = 0
  proc controlWordFetchAdd*[K](s: var ShmGSetT[K]; i: int; d: uint64): uint64 = 0
  proc controlWordBumpTo*[K](s: var ShmGSetT[K]; i: int; target: uint64): uint64 = 0
  iterator items*[K](s: var ShmGSetT[K]): seq[byte] = discard
  proc snapshot*[K](s: var ShmGSetT[K]): seq[seq[byte]] = @[]
  proc shardCount*[K](s: var ShmGSetT[K]): int = 0
  proc claimedSlots*[K](s: var ShmGSetT[K]): uint64 = 0
  proc growthFailures*[K](s: var ShmGSetT[K]): uint64 = 0
  proc markConsumerGone*[K](s: var ShmGSetT[K]) = discard
  proc consumerAlive*[K](s: ShmGSetT[K]): bool = false
  proc shardIsDrained*[K](s: var ShmGSetT[K]; k: int): bool = false
  proc markShardDrained*[K](s: var ShmGSetT[K]; k: int): bool {.discardable.} = false
  proc retireShard*[K](s: var ShmGSetT[K]; k: int): bool {.discardable.} = false
  proc assertNoAbsolutePointers*[K](s: var ShmGSetT[K]) = discard
  proc shards0Base*[K](s: ShmGSetT[K]): pointer = nil
  proc reapStaleSegments*(dir, appId: string): int = 0
