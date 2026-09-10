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
## (`extraControlWords`) — e.g. for a generation counter used to order
## tombstones — and MUST override `keyFormatVersion` so a chain written under one
## key discipline is never attached under another (`headerCheck` rejects it).
##
## ============================================================================
## RECYCLING (`reset`)
## ============================================================================
##
## The chain carries a GENERATION, authoritative in shard0 and published by one
## release store. Every slot entry packs `(generation shl 32) or offset`, and
## every per-shard counter (arena bump pointer, occupancy, growth failures) is
## stamped the same way, so anything written under another generation reads as
## EMPTY and rebases itself on first use. Recycling a grown chain into a fresh
## empty set is therefore that single store — O(1) at any chain size, with the
## already-grown shards kept — which is what makes a long-lived host able to
## hand one chain to action after action instead of growing a new one each time.
##
## It is CONSUMER-ONLY and it REFUSES rather than trusting its caller: a
## producer between its arena reserve and its slot publish when the generation
## flips would land bytes in the recycled set, attributed to the NEXT action.
## `reset` checks a producer registry, seals the window between that check and
## the commit, re-arms the consumer-liveness token before the commit, and writes
## the new run identity into the runId slot the NEXT generation selects, so a
## crash leaves the chain fully-old or fully-new. See `reset` and README.md
## ("Reset and recycling").
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
  ## stem (`{appId}~{chainSeq}.{boot}.{pid}`). An appId MUST NOT contain it (see
  ## `validAppId` / `createSet`), so the reaper recovers the appId unambiguously
  ## by splitting the stem at its FIRST occurrence. This is what lets
  ## `reapStaleSegments` scope to ONE app and never touch (or even
  ## liveness-check) another app's segments.
  ##
  ## The stem carries ONLY what the reaper needs to SCOPE and to judge STALENESS:
  ## the appId, the creating boot id and the owner pid, plus an opaque
  ## `chainSeq` that makes two chains owned by one process distinct on disk. The
  ## run IDENTITY (`runId`) is NOT in the name — it lives in shard0's header
  ## (`ShOffRunId`), so a recycled chain can be re-stamped in place without
  ## renaming a single file and can never carry a stale name-borne runId.

func validAppId*(appId: string): bool =
  ## An appId is a filesystem-safe, separator-free tag. Reject empty, the
  ## reserved `~` separator, and the path separator `/` (which would break the
  ## `dir/stem` layout). Dots ARE allowed — the reserved separator makes them
  ## unambiguous.
  appId.len > 0 and AppIdSep notin appId and '/' notin appId

func alignUp*(n, a: int): int {.inline.} = (n + a - 1) and not (a - 1)

const
  ShmGSetMagicBase* = 0x5347_4D48_53_00_00'u64
    ## "SHM SG" with the layout-revision byte cleared. FROZEN FOR ALL TIME: the
    ## magic word sits at offset 0 in every revision that has ever existed and
    ## its high seven bytes are this constant, so ANY build can look at ANY
    ## shard file and answer "is this a shm_gset shard, and which header layout
    ## revision is it?" without understanding the rest of the file. That is what
    ## makes a version skew DIAGNOSABLE instead of merely fatal
    ## (`shardLayoutRevision`, `afLayoutSkew`).
  MagicRevisionMask* = 0xFFFF_FFFF_FFFF_FF00'u64
    ## Masks the layout-revision byte off a magic word, leaving the frozen
    ## `ShmGSetMagicBase` identity. FROZEN alongside it.
  ShmGSetLayoutRevision* = 3'u64
    ## THIS build's header layout revision (the magic's low byte).
    ##
    ## Revision 3 (HM-2, reset/recycling): every slot entry is GENERATION
    ## STAMPED — the entry packs `(generation shl 32) or offset` instead of a
    ## bare offset — and the header gained the chain generation, the two
    ## alternating `runId` slots, the producer registry and the attach counters.
    ## A chain is recycled by bumping one word, so nothing in the shard files may
    ## be read without matching it against the current generation.
  ShmGSetMagic* = ShmGSetMagicBase or ShmGSetLayoutRevision
  ShmGSetMagicV1* = ShmGSetMagicBase or 1'u64
    ## The pre-HM-1 layout: no in-header `runId`, 128-byte header, and the runId
    ## carried in the FILE NAME.
  ShmGSetMagicV2* = ShmGSetMagicBase or 2'u64
    ## The HM-1 layout: in-header `runId` at a fixed offset, 256-byte header,
    ## un-stamped slot entries (a bare arena offset).
    ##
    ## Neither legacy magic is ever attached — `headerCheck` accepts only the
    ## CURRENT revision — but they ARE now distinguished from "not a shard at
    ## all": an attach that fails on the layout revision reports `afLayoutSkew`
    ## (see `attachFailure`), which is the difference between a diagnosable
    ## version skew and a silently empty dependency set. The reaper also does not
    ## test for these values: it reads any non-current magic as "no header
    ## identity" (`readAnchorRunId`) and falls back to the NAME component, so a
    ## legacy chain is still judged and collected by the ordinary staleness rule
    ## rather than skipped and leaked. Both constants are exported so the
    ## migration and skew tests can write out genuine legacy shards rather than
    ## stubs.
  ShmGSetFormatVersion* = 1'u32
    ## Format version of the DEFAULT (`IdentityKey`) key discipline. A policy
    ## with a different discipline must pick its own via `keyFormatVersion`.

type
  AttachFailure* = enum
    ## WHY an attach did not produce a usable view. `available == false` is the
    ## conservative outcome in every case (LF-2: the caller fails fast and never
    ## spills), but the REASONS are not interchangeable and one of them —
    ## `afLayoutSkew` — is a build/deploy fault rather than a runtime condition.
    ##
    ## WHY THIS EXISTS. Before it, a producer built against a different header
    ## layout than the chain it was handed simply returned "unavailable": the
    ## edge graded `mcIncomplete` and the dependency set came back EMPTY with no
    ## error anywhere. It degrades in the safe direction (never a false cache
    ## hit) but INVISIBLY, and a header layout revision has now moved twice. The
    ## enum makes the skew nameable at the point it is detected; `producerAttaches`
    ## makes its ABSENCE observable from the host side (see below).
    afNone                ## attached; `available` is true
    afBadPath             ## the path does not name a `.shard0` anchor
    afMissing             ## no such file, or it could not be opened
    afTruncated           ## smaller than one shard header: not a shard
    afMapFailed           ## `mmap` failed
    afNotAShard           ## the magic's frozen high bytes are wrong — this file
                          ## was never written by any version of this library
    afLayoutSkew          ## a genuine shm_gset shard of a DIFFERENT header
                          ## layout revision: this build and the writer disagree
                          ## about the on-disk shape. A VERSION SKEW.
    afKeyDisciplineSkew   ## right layout, different `keyFormatVersion` — the
                          ## chain was written under another key discipline
    afWrongBoot           ## created on a different boot: a stale segment the
                          ## reaper has not collected yet
    afRecycling           ## the chain was being RESET for the whole time this
                          ## attach waited. A producer of the action that just
                          ## ended; its evidence has already been read

# --- shard file header (offset-only, base-independent) ----------------------
#
# All 8-byte fields on 8-byte-aligned offsets. shard0 is authoritative for the
# control block (chainCount / growthFailed / consumer-liveness / runId); those
# fields are present but unused in shards > 0.
#
# `runId` is the chain's RUN IDENTITY and lives here rather than in the file
# name, so a chain can be re-stamped in place (recycling) without renaming its
# shard files, and so a reused chain can never carry a stale name-borne runId.
# It is a length-prefixed, NUL-padded byte field; only shard0's copy is
# meaningful (a growth shard is created by a PRODUCER, which does not know the
# runId, and writes length 0).
#
# There are TWO runId slots, selected by the low bit of the CURRENT GENERATION.
# `reset` stamps the new identity into the slot the NEXT generation will select
# — the one nothing is reading — and only then publishes the generation. The
# generation store is therefore the single commit point for the identity as well
# as for the contents: a crash anywhere before it leaves the chain FULLY OLD
# (old generation, old runId), and a crash after it leaves it FULLY NEW. A
# single in-place runId field could not give that: the window between rewriting
# it and bumping the generation is a chain whose old contents carry the NEXT
# action's identity, which is precisely the cross-attribution this design exists
# to prevent.
#
# GENERATION. `ShOffGeneration` is the chain's generation counter, authoritative
# in shard0 and published with a RELEASE store. Every slot entry, every arena
# bump pointer, every occupancy and growth-failure counter is stamped with the
# generation that wrote it and reads as EMPTY / ZERO under any other. Recycling
# a chain is therefore one store, independent of how large the chain grew.
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
  ShOffArenaUsed* = 64                     # u64 (atomic bump, GENERATION-STAMPED:
                                           #      (gen shl 32) or usedBytes)
  ShOffOccupied* = 72                      # u64 (atomic claimed-slot count,
                                           #      GENERATION-STAMPED)
  # control block (shard0 authoritative):
  ShOffChainCount* = 80                    # u64 (atomic; number of shards, >=1)
                                           #      NOT generation-stamped: the
                                           #      grown shards are exactly what
                                           #      recycling keeps.
  ShOffGrowthFailed* = 88                  # u64 (atomic; SIGNALLED saturation,
                                           #      GENERATION-STAMPED)
  ShOffConsumerPid* = 96                   # u64
  ShOffConsumerBoot* = 104                 # u64
  ShOffConsumerAlive* = 112                # u64 (atomic; re-armed by `reset`
                                           #      BEFORE the generation store)
  ShOffGeneration* = 120                   # u64 (atomic; THE RESET COMMIT POINT)
  ShOffProducerOverflow* = 128             # u64 (atomic; producers currently
                                           #      attached that could not claim a
                                           #      registry slot)
  ShOffProducerAttaches* = 136             # u64 (atomic, GENERATION-STAMPED;
                                           #      successful producer attaches
                                           #      under the current generation)
  ShOffResetSeal* = 144                    # u64 (SEQ_CST; nonzero while a reset
                                           #      is in progress — closes the
                                           #      attach-during-reset window,
                                           #      see `reset`)
  # 152 .. 192 reserved
  ShOffRunIdSlots* = 192                   # two runId slots, `generation and 1`
  RunIdSlotBytes* = 128                    # [len u32][pad u32][120 bytes]
  RunIdSlotHdr* = 8                        # bytes before the runId content
  RunIdMaxBytes* = 120                     # capacity of one runId slot
  ShOffProducers* = 448                    # producer registry: one u64 pid per
                                           # entry, 0 == free (shard0 only is
                                           # authoritative, as for the rest of
                                           # the control block)
  MaxRegisteredProducers* = 128
  ShardHeaderSize* = ShOffProducers + MaxRegisteredProducers * 8   # 1472
  ShOffExtraControl* = ShardHeaderSize     # policy-declared extra control words
                                           # (u64 each) start here; shard0 is
                                           # authoritative, as for the rest of
                                           # the control block.

const
  SlotGenShift* = 32
    ## A slot entry is `(generation shl SlotGenShift) or offset`. The generation
    ## occupies the high 32 bits and the arena offset the low 32, so a shard file
    ## may not exceed `MaxShardBytes` and a chain may not exceed
    ## `MaxGeneration` recycles. Both bounds are ENFORCED rather than assumed —
    ## see `appendShardFile` (growth beyond the bound is a SIGNALLED saturation)
    ## and `reset` (`rsGenerationExhausted`).
  SlotOffMask* = (1'u64 shl SlotGenShift) - 1
  MaxShardBytes* = 1'u64 shl SlotGenShift
    ## Hard cap on one shard file, so every in-shard offset fits the low half of
    ## a slot entry. 4 GiB per shard; the chain as a whole is unbounded because
    ## it keeps sharding.
  MaxGeneration* = SlotOffMask
    ## The last usable generation. Generations start at 1 and never wrap: a
    ## chain that reaches this refuses further recycling (`rsGenerationExhausted`)
    ## and the caller creates a new chain. Wrapping would make a 4-billion-resets
    ## -old slot read as live under the reused generation — a cross-generation
    ## leak — and the alternative (scrubbing every slot on wrap) is both
    ## O(capacity) and NOT crash-atomic, since it destroys the old generation's
    ## contents before the commit point. Refusing is O(1), crash-safe, and the
    ## cost of a new chain once per 4.29e9 recycles is nil.
  GenerationNone* = 0'u64
    ## The generation of a freshly `ftruncate`d (all-zero) region. Never a live
    ## generation, so an un-stamped counter or slot reads as empty in every
    ## generation without anything having to initialise it.

func slotEntryGen*(entry: uint64): uint64 {.inline.} = entry shr SlotGenShift
func slotEntryOff*(entry: uint64): int {.inline.} = int(entry and SlotOffMask)
func packSlotEntry*(gen: uint64; off: int): uint64 {.inline.} =
  (gen shl SlotGenShift) or (uint64(off) and SlotOffMask)
func slotIsLive*(entry, gen: uint64): bool {.inline.} =
  ## A slot holds a live element of generation `gen` iff it was stamped with it.
  ## Generations start at 1, so this also rejects the never-written entry 0 and
  ## makes "reset" a single store rather than a walk over the slot array.
  entry != 0'u64 and slotEntryGen(entry) == gen

func genStampedValue*(word, gen: uint64): uint64 {.inline.} =
  ## Read a generation-stamped counter: its value under `gen`, or 0 if it was
  ## last written under a different generation (so `reset` need not touch it).
  if (word shr SlotGenShift) == gen: word and SlotOffMask else: 0'u64
func packGenStamped*(gen, value: uint64): uint64 {.inline.} =
  (gen shl SlotGenShift) or (value and SlotOffMask)

const ShFlagDrained* = 1'u32
  ## Header flag: every LIVE element of this shard has been copied forward into a
  ## newer shard, so readers may skip it (§ flattening/retirement). Set by a
  ## flattener with a release CAS AFTER all copies succeed; never cleared.

# One slot is a single u64 "entry": `(generation shl 32) or offset`, where
# `offset` is the absolute byte offset (within THIS shard's mapping) of the
# element's arena record. 0 == never written; an entry whose generation is not
# the chain's CURRENT generation is likewise empty. Published by ONE release CAS
# (empty-or-stale -> stamped offset), so a reader that acquire-observes a live
# entry also observes the fully-written record it points at.
#
# The generation lives IN the entry rather than beside it precisely so the claim
# stays a single-word CAS: a (generation, offset) pair in two words could not be
# claimed atomically, and a claim that is not atomic is a torn slot.
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
  ## after the fixed `ShardHeaderSize` block (shard0's are the authoritative
  ## ones). They are opaque atomics the POLICY owns — e.g. a generation counter
  ## that totally orders tombstones against records, or a bypass counter.
  ## Default 0, which puts the slot array at `ShardHeaderSize` exactly.
  ##
  ## NOT where the CHAIN's recycling generation lives. That one is a field of
  ## the fixed header (`ShOffGeneration`), for two reasons: these words belong
  ## to the key discipline — the action-cache policy already uses word 0 for its
  ## own tombstone generation, which the library would have had to take over —
  ## and reserving one for every discipline would shift the slot array for all
  ## of them. The chain generation is a library-level concept that every key
  ## discipline needs, so it belongs in the header rather than in a
  ## policy-declared extension of it.
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

  ResetStatus* = enum
    ## The outcome of `reset`. It is a RETURNED STATUS, not a `void` with a
    ## documented precondition, because reset's whole point is that it REFUSES:
    ## a precondition nobody enforces is a comment, and a refusal nobody can
    ## observe is the same thing one call frame later. The result is deliberately
    ## not `discardable` — silently ignoring `rsBusyProducers` and handing the
    ## chain to the next action is exactly the cross-attribution this guards.
    rsReset                ## recycled: a fresh, empty set under a new generation
    rsBusyProducers        ## REFUSED: at least one LIVE attached producer may
                           ## be mid-insert. TRANSIENT — it clears when those
                           ## processes exit. See `attachedProducers`.
    rsProducersUntracked   ## REFUSED: a producer attached when the registry was
                           ## full, so the chain never learned its pid and
                           ## cannot tell whether it is still running. Refusing
                           ## is conservative and costs only the recycling, but
                           ## unlike `rsBusyProducers` it may be PERMANENT (if
                           ## that producer died without detaching), so a pool
                           ## should retire this chain rather than retry it. It
                           ## needs more than `MaxRegisteredProducers`
                           ## simultaneously attached producers to arise at all.
    rsUnavailable          ## not a live, consumer-owned, attached chain
    rsNotConsumer          ## called on a producer view: reset is consumer-only
    rsInvalidRunId         ## the runId does not fit `RunIdMaxBytes`
    rsGenerationExhausted  ## this chain has been recycled `MaxGeneration` times;
                           ## it cannot be recycled again (create a new chain)

  ReapedSegment* = object
    ## One chain the reaper collected, with the identity it was ATTRIBUTED to.
    ## `reapStaleSegments` returns only the file count; this is the same walk
    ## with the attribution kept, for a caller that reports or audits what was
    ## collected.
    anchor*: string          ## path of the reaped shard0
    runId*: string           ## the chain's run identity
    runIdFromHeader*: bool   ## true  ⇒ `runId` was read from shard0's HEADER
                             ## false ⇒ the header was unreadable (a LEGACY
                             ##         pre-HM-1 chain, a truncated leftover, or
                             ##         not a shard at all) and `runId` is the
                             ##         best-effort name component the old
                             ##         `{appId}~{runId}.{boot}.{pid}` scheme
                             ##         carried there. Never trust it as
                             ##         identity; it exists so a migration is
                             ##         diagnosable rather than opaque.
    boot*: uint64            ## creating boot id, from the NAME (staleness axis)
    ownerPid*: uint64        ## owner pid, from the NAME (staleness axis)
    filesRemoved*: int       ## shard files unlinked for this chain

func validRunId*(runId: string): bool =
  ## A runId must fit the fixed-size header field (`RunIdMaxBytes`). It is
  ## otherwise unconstrained — dots, tildes and path separators are all fine now
  ## that it is not part of any file name. `createSetT` REFUSES a longer one
  ## rather than truncating: a silently shortened identity is a
  ## misattribution waiting to happen.
  runId.len <= RunIdMaxBytes

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
      basePrefix: string        ## dir/{appId}~{chainSeq}.{boot}.{pid}
      path0*: string            ## shard0 path — the well-known REPRO_MONITOR name
      boot: uint64
      shards: seq[ShardMap]     ## index == shardId; lazily mapped
      tmpCtr: int
      failure: AttachFailure    ## why `available` is false (see `attachFailure`)
      producerPid: uint64       ## the pid that claimed `producerSlot`. A FORKED
                                ## child inherits this handle verbatim, so the
                                ## release path compares it against the caller's
                                ## own pid — see `unregisterProducer`.
      producerSlot: int         ## registry index claimed by this producer view;
                                ## -1 == attached but UNREGISTERED (the registry
                                ## was full — counted in `ShOffProducerOverflow`),
                                ## -2 == not a registered producer at all
                                ## (a consumer view, or never attached)

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
  # SEQ_CST trio, used ONLY for the reset-seal / producer-registration
  # handshake. That handshake is a store-buffer (Dekker) shape — reset stores
  # the seal then reads the registry, a producer claims a registry entry then
  # reads the seal — and the outcome "neither sees the other" is permitted by
  # acquire/release AND by x86-TSO. Only a total order over the four accesses
  # forbids it, so these four are the only sequentially-consistent operations in
  # the library and their cost is paid once per attach and once per reset, never
  # on the insert path.
  proc loadU64Seq(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_SEQ_CST)
  proc storeU64Seq(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_SEQ_CST)
  proc casU64Seq(base: ShmBase; off: int; expected: var uint64;
      desired: uint64): bool {.inline.} =
    atomicCompareExchangeN(atField(base, off, uint64), addr expected, desired,
      false, ATOMIC_SEQ_CST, ATOMIC_SEQ_CST)
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

  when defined(macosx):
    proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
        newp: pointer; newlen: csize_t): cint
      {.importc, header: "<sys/sysctl.h>".}

  proc bootId*(): uint64 =
    ## Per-boot identity — the value the header guard compares a shard's
    ## creator against, so that a chain surviving in a file-backed directory
    ## across a REBOOT is judged stale and recreated rather than read.
    ## Never zero.
    ##
    ## IT MUST BE CONSTANT FOR THE LIFE OF A BOOT, and on macOS it was not. The
    ## fallback below is `now()`, which changes every second, so on Darwin two
    ## processes attaching a chain one second apart disagreed about the boot and
    ## the second one judged a perfectly live chain stale. For io-mon that was
    ## invisible — its dependency-capture channel is Linux-only and reads
    ## `/proc/sys/kernel/random/boot_id`. For a chain that is HOST-WIDE and
    ## LONG-LIVED, as reprobuild's action-cache index is, it is fatal in a quiet
    ## way: every engine start recreates the chain empty, the tier is
    ## permanently cold, and nothing reports an error because a cold index is
    ## indistinguishable from a new one. Measured before the fix: insert an
    ## element, wait three seconds, attach from another process — `available`
    ## is true and the element count is zero.
    ##
    ## `kern.boottime` is the authoritative answer on Darwin: a `struct
    ## timeval` fixed at boot, to microsecond resolution, so it also
    ## distinguishes two boots inside one second. The wall-clock fallback is
    ## kept only for a platform that has neither source; on such a host a chain
    ## is recreated more often than it needs to be, which costs a warm-up and
    ## never correctness.
    when defined(linux):
      try:
        let raw = readFile("/proc/sys/kernel/random/boot_id")
        var h: uint64 = 1469598103934665603'u64
        for ch in raw:
          if ch != '-' and ch != '\n':
            h = (h xor uint64(ord(ch))) * 1099511628211'u64
        return (h or 1'u64)
      except CatchableError: discard
    elif defined(macosx):
      var tv: Timeval
      var size = csize_t(sizeof(tv))
      if sysctlbyname("kern.boottime", addr tv, addr size, nil, 0) == 0 and
          size == csize_t(sizeof(tv)):
        let secs = uint64(tv.tv_sec)
        let usecs = uint64(tv.tv_usec)
        if secs != 0'u64:
          return ((secs * 1_000_000'u64 + usecs) or 1'u64)
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

  const ArenaGuardBytes = 8
    ## The arena bump pointer starts here rather than at 0, so an arena-relative
    ## offset of 0 is never handed out. Kept from the pre-generation layout: it
    ## costs one word and keeps the arena's first record at the same place.

  proc runIdSlotOff(gen: uint64): int {.inline.} =
    ## Which of the two runId slots the given generation reads. `reset` writes
    ## the OTHER one and then publishes the generation, so the identity flips
    ## atomically with the contents.
    ShOffRunIdSlots + int(gen and 1'u64) * RunIdSlotBytes

  proc writeRunIdSlot(base: ShmBase; gen: uint64; runId: string) =
    ## Stamp `runId` into the slot generation `gen` will select. The whole slot
    ## is zeroed first: a re-stamp must not leave a tail of the previous identity
    ## behind the new length, where a corrupt length word would expose it.
    let off = runIdSlotOff(gen)
    zeroMem(addr base[off], RunIdSlotBytes)
    let rn = min(runId.len, RunIdMaxBytes)
    if rn > 0: copyMem(addr base[off + RunIdSlotHdr], unsafeAddr runId[0], rn)
    storeU32Release(base, off, uint32(rn))

  proc initShardHeader(base: ShmBase; shardId, cap, arenaCap: int;
      boot: uint64; chainCount: uint64; fmtVersion: uint32; extraWords: int;
      generation = GenerationNone; runId = "") =
    ## `runId` and `generation` are the chain's identity and are meaningful only
    ## in shard0; a growth shard is appended by a PRODUCER, which does not own
    ## either, and leaves them zero.
    ##
    ## Note what is NOT written here: the arena bump pointer, the occupancy
    ## counter and the growth-failure counter are left at 0, which is
    ## `GenerationNone` and therefore reads as empty under EVERY live generation.
    ## That is what lets a growth shard appended in one generation be reused
    ## verbatim by the next one, and what makes `reset` O(1) instead of a walk
    ## over the chain.
    let slotsOff = slotsOffFor(extraWords)
    storeU32Relaxed(base, ShOffFlags, 0)
    storeU64Relaxed(base, ShOffCreatorBootId, boot)
    storeU64Relaxed(base, ShOffShardId, uint64(shardId))
    storeU64Relaxed(base, ShOffCapacity, uint64(cap))
    storeU64Relaxed(base, ShOffSlotsOff, uint64(slotsOff))
    storeU64Relaxed(base, ShOffArenaOff, uint64(alignUp(slotsOff + cap * SlotSize, 64)))
    storeU64Relaxed(base, ShOffArenaCap, uint64(arenaCap))
    storeU64Relaxed(base, ShOffArenaUsed, 0)   # un-stamped: rebases on first use
    storeU64Relaxed(base, ShOffOccupied, 0)
    storeU64Relaxed(base, ShOffChainCount, chainCount)
    storeU64Relaxed(base, ShOffGrowthFailed, 0)
    storeU64Relaxed(base, ShOffConsumerPid, 0)
    storeU64Relaxed(base, ShOffConsumerBoot, 0)
    storeU64Relaxed(base, ShOffConsumerAlive, 0)
    storeU64Relaxed(base, ShOffProducerOverflow, 0)
    storeU64Relaxed(base, ShOffProducerAttaches, 0)
    storeU64Relaxed(base, ShOffResetSeal, 0)
    zeroMem(addr base[ShOffRunIdSlots], 2 * RunIdSlotBytes)
    zeroMem(addr base[ShOffProducers], MaxRegisteredProducers * 8)
    if generation != GenerationNone:
      writeRunIdSlot(base, generation, runId)
    storeU64Relaxed(base, ShOffGeneration, generation)
    for i in 0 ..< extraWords:
      storeU64Relaxed(base, ShOffExtraControl + i * 8, 0)
    storeU32Release(base, ShOffFormatVersion, fmtVersion)
    # Publish magic LAST (release): an attacher that sees the magic also sees the
    # fully-initialised header + zeroed slots/arena.
    storeU64Release(base, ShOffMagic, ShmGSetMagic)

  proc headerGeneration(base: ShmBase): uint64 {.inline.} =
    ## The chain's CURRENT generation, from shard0's header. ACQUIRE, because it
    ## is the release-published commit point of `reset`: a reader that observes
    ## generation N also observes everything `reset` wrote before publishing it
    ## (the re-armed consumer-liveness token and the new runId slot).
    loadU64Acquire(base, ShOffGeneration)

  proc headerRunId(base: ShmBase): string =
    ## The chain's run identity out of a MAPPED header (shard0 is the
    ## authoritative one), from the slot the CURRENT generation selects.
    ## Bounds-checked: a length outside the slot reads as "no identity" rather
    ## than as arbitrary bytes.
    let off = runIdSlotOff(headerGeneration(base))
    let n = int(loadU32Acquire(base, off))
    if n <= 0 or n > RunIdMaxBytes: return ""
    result = newString(n)
    copyMem(addr result[0], addr base[off + RunIdSlotHdr], n)

  proc headerCheck(base: ShmBase; boot: uint64;
      fmtVersion: uint32): AttachFailure =
    ## WHY this header may not be used, in the order the reasons stop mattering.
    ##
    ## The layout-revision test comes first and is answered from the FROZEN part
    ## of the magic alone, so a shard written by any other revision of this
    ## library is reported as a VERSION SKEW (`afLayoutSkew`) rather than lumped
    ## in with "not a shard" or with a stale segment. Nothing beyond the magic is
    ## trusted before that test passes: by definition this build does not know
    ## where the other revision put its fields.
    let magic = loadU64Acquire(base, ShOffMagic)
    if magic == ShmGSetMagic:
      discard
    elif (magic and MagicRevisionMask) == ShmGSetMagicBase:
      return afLayoutSkew           # a real shm_gset shard, another revision
    else:
      return afNotAShard
    if loadU32Acquire(base, ShOffFormatVersion) != fmtVersion:
      return afKeyDisciplineSkew
    if loadU64Relaxed(base, ShOffCreatorBootId) != boot:
      return afWrongBoot
    afNone

  proc mapShardFromFd(fd: cint; size: int; boot: uint64; fmtVersion: uint32;
      failure: var AttachFailure): ShardMap =
    let base = mapFd(fd, size)
    if base.isNil:
      failure = afMapFailed; return
    let why = headerCheck(base, boot, fmtVersion)
    if why != afNone:
      failure = why
      discard munmap(cast[pointer](base), size); return
    result.base = base
    result.size = size
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
        except CatchableError:
          s.failure = afMissing; return false
        if size <= ShardHeaderSize:
          s.failure = afTruncated; return false
        let fd = open(path.cstring, O_RDWR)
        if fd < 0:
          s.failure = afMissing; return false
        var why = afNone
        let sm = mapShardFromFd(fd, size, s.boot, keyFormatVersion(K), why)
        discard close(fd)
        if sm.base.isNil:
          s.failure = why
          return false
        if k >= s.shards.len: s.shards.setLen(k + 1)
        s.shards[k] = sm
        return true
      if not patient:
        s.failure = afMissing; return false
      inc tries
      if tries > 10000:
        s.failure = afMissing; return false
      discard sched_yield()

  proc chainCount[K](s: var ShmGSetT[K]): int {.inline.} =
    int(loadU64Acquire(s.shards[0].base, ShOffChainCount))

  proc currentGeneration[K](s: var ShmGSetT[K]): uint64 {.inline.} =
    ## The chain's generation, re-read from shard0 at the START of every
    ## operation rather than cached on the handle.
    ##
    ## Re-reading is what makes an in-flight producer FAIL SAFE if the quiescence
    ## check is ever bypassed: a producer that read generation N and publishes
    ## its slot after the bump to N+1 stamps N, so its bytes land in the segment
    ## but are UNREACHABLE in N+1. The leak direction is "the old action's
    ## evidence is dropped", never "the old action's evidence is attributed to
    ## the new one" — the cardinal sin stays impossible even when the
    ## precondition is violated. It is defence in depth, not a substitute for the
    ## refusal: a producer that reads N+1 and inserts is still mis-attributed,
    ## which is why `reset` refuses while any producer is attached.
    if s.shards.len == 0 or s.shards[0].base.isNil: return GenerationNone
    headerGeneration(s.shards[0].base)

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
    ## zero-copy view of the stored bytes. The caller has already established
    ## that `entry` is live in the current generation.
    mixin identityEq
    let off = slotEntryOff(entry)
    if loadU64Acquire(base, off + ArenaRecFp) != ifp: return false
    let n = int(loadU32Acquire(base, off + ArenaRecLen))
    identityEq(K, base.toOpenArray(off + ArenaRecBytes, off + ArenaRecBytes + n - 1),
      blob)

  proc reserveArena(base: ShmBase; gen: uint64; recSize,
      arenaCap: int): int =
    ## Lock-free, GENERATION-REBASING bump allocation. Returns the arena-relative
    ## offset, or -1 when this shard's arena is exhausted for this generation.
    ##
    ## The bump pointer is `(generation shl 32) or usedBytes`, so the FIRST
    ## reserve of a new generation implicitly rebases it to the guard word: the
    ## previous generation's bytes stay resident but are unreachable (no slot
    ## referencing them is stamped with the current generation) and no one has to
    ## walk the chain to reclaim them. That is what makes `reset` O(1) rather
    ## than O(shards).
    ##
    ## It is a CAS loop rather than the fetch-add it replaces because the rebase
    ## and the bump must be one atomic step; a fetch-add cannot conditionally
    ## reset its own base. Still lock-free: every failed CAS means some other
    ## producer's reserve succeeded.
    var cur = loadU64Acquire(base, ShOffArenaUsed)
    while true:
      let used = int(genStampedValue(cur, gen))
      let base0 = if used == 0: ArenaGuardBytes else: used
      if base0 + recSize > arenaCap: return -1
      let desired = packGenStamped(gen, uint64(base0 + recSize))
      scheduleHook(spBeforeArenaReserve)
      if casU64(base, ShOffArenaUsed, cur, desired): return base0
      # `cur` now holds the value that beat us; recompute against it.

  proc bumpGenStamped(base: ShmBase; off: int; gen, delta: uint64) =
    ## Add `delta` to a generation-stamped counter, rebasing from 0 if the
    ## counter was last written under another generation.
    var cur = loadU64Acquire(base, off)
    while true:
      let desired = packGenStamped(gen, genStampedValue(cur, gen) + delta)
      if casU64(base, off, cur, desired): return

  type InsertShardResult = enum siInserted, siExists, siNeedGrow

  proc insertIntoShard(K: typedesc; sm: var ShardMap; blob: openArray[byte];
      keyHash, ifp, gen: uint64): InsertShardResult =
    let base = sm.base
    let cap = sm.cap
    let mask = uint64(cap - 1)
    var idx = int(keyHash and mask)   # HOME SLOT: derived from the PRIMARY KEY,
                                      # so every element sharing a primary key
                                      # starts (and therefore lands) in one run.
    var probes = 0
    while probes < cap:
      let slotOff = sm.slotsOff + idx * SlotSize
      var entry = loadU64Acquire(base, slotOff)
      if not slotIsLive(entry, gen):
        # Empty for THIS generation — never written, or written by a previous
        # one and therefore unreachable. Reserve arena, write the record fully,
        # THEN publish via a single release CAS (the sole shared mutation — an
        # idempotent slot-claim). The CAS expects the exact stale value observed,
        # so a stale slot is recycled in place with no extra step and two racing
        # producers still have exactly one winner.
        let recSize = alignUp(ArenaRecHdr + blob.len, 8)
        let aoff = reserveArena(base, gen, recSize, sm.arenaCap)
        if aoff < 0:
          return siNeedGrow          # arena exhausted -> shard, never drop
        let absOff = sm.arenaOff + aoff
        storeU64Relaxed(base, absOff + ArenaRecFp, ifp)
        storeU32Relaxed(base, absOff + ArenaRecLen, uint32(blob.len))
        if blob.len > 0:
          copyMem(addr base[absOff + ArenaRecBytes], unsafeAddr blob[0], blob.len)
        scheduleHook(spBeforeArenaPublish)
        var expected = entry
        scheduleHook(spBeforeSlotCas)
        if casU64(base, slotOff, expected, packSlotEntry(gen, absOff)):
          scheduleHook(spAfterSlotCas)
          bumpGenStamped(base, ShOffOccupied, gen, 1)
          return siInserted
        scheduleHook(spAfterSlotCas)
        # Lost the slot to a racer; `expected` now holds the winner's entry. If
        # it is our element, we are a duplicate (our arena bytes are wasted —
        # bounded, reclaimed by the next generation). A winner stamped with an
        # OLDER generation cannot happen (only this generation's producers write),
        # but the liveness test is applied anyway so a bypassed quiescence check
        # degrades to "probe on", never to "read a foreign generation's bytes".
        entry = expected
        if slotIsLive(entry, gen) and entryMatches(K, base, entry, ifp, blob):
          return siExists
        idx = (idx + 1) and int(mask); inc probes; continue
      else:
        if entryMatches(K, base, entry, ifp, blob): return siExists
        idx = (idx + 1) and int(mask); inc probes; continue
    siNeedGrow                       # table full -> shard, never drop

  proc shouldGrow(sm: ShardMap; gen: uint64): bool {.inline.} =
    let occ = genStampedValue(loadU64Relaxed(sm.base, ShOffOccupied), gen)
    occ * uint64(LoadDen) >= uint64(sm.cap * LoadNum)

  # Process-global tmp uniquifier. A per-`ShmGSet` counter is NOT enough: two
  # producer THREADS in the same process share `getpid()` and both start their
  # own `tmpCtr` at 1, so they would forge the SAME `.shardtmp.<pid>.1` name and
  # the `O_EXCL` loser's `EEXIST` would be misreported as a growth failure
  # (SIGNALLED saturation) even though growth succeeded. An atomic process-global
  # sequence makes every temp name unique across threads.
  var gShardTmpSeq: uint64

  # Process-global chain uniquifier (the `chainSeq` component of an anchor
  # name). Atomic for the same reason as `gShardTmpSeq`: two host THREADS in one
  # process would otherwise forge the same anchor name.
  var gChainSeq: uint64

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
    if uint64(size) >= MaxShardBytes:
      # An in-shard arena offset must fit the low half of a slot entry. Growing
      # past the cap would silently truncate every offset in the new shard, so
      # growth FAILS here instead — the SIGNALLED saturation path (LF: never a
      # silent drop, and `growthFailures > 0` grades the edge `mcIncomplete`).
      return false
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

  proc growNewest[K](s: var ShmGSetT[K]; expectedN: int; full: ShardMap;
      gen: uint64): bool =
    ## Append a new, larger shard at index `expectedN` (or observe that someone
    ## else already did). Returns false only when growth itself fails (OOM, or
    ## the `MaxShardBytes` cap) — the SIGNALLED saturation case.
    if chainCount(s) > expectedN: return true    # already grew
    let newCap = full.cap * GrowthFactor
    let newArenaCap = full.arenaCap * GrowthFactor
    if not appendShardFile(s, expectedN, newCap, newArenaCap):
      bumpGenStamped(s.shards[0].base, ShOffGrowthFailed, gen, 1)
      return false
    bumpChainCountTo(s, expectedN + 1)
    return true

  # --- public API -----------------------------------------------------------

  proc shardBasePrefix*(dir, appId: string;
      chainSeq, boot, ownerPid: uint64): string =
    ## The chain's base name; `shard{K}` is appended per shard. Encodes ONLY
    ## what the reaper needs — `dir/{appId}~{chainSeq}.{boot}.{pid}`: the appId
    ## scopes it (one app never reaps another's segments) and boot + owner pid
    ## let it judge staleness (design spec §4.3.4).
    ##
    ## `chainSeq` is an OPAQUE per-owner uniquifier, not an identity: it exists
    ## only so one process can own several chains at once without them colliding
    ## on disk. The run identity lives in shard0's header — see `runId`.
    ##
    ## The component layout is deliberately the same SHAPE as the pre-HM-1
    ## `{appId}~{runId}.{boot}.{pid}`, so the reaper's `rsplit('.', 2)` finds
    ## boot and pid in the same positions for a legacy chain as for a current
    ## one and a legacy chain is still collected rather than skipped.
    dir / (appId & AppIdSep & $chainSeq & "." & $boot & "." & $ownerPid)

  proc createSetT*[K](dir, appId, runId: string; keyPolicy: typedesc[K];
      shard0Cap = 1024; shard0ArenaCap = 256 * 1024): ShmGSetT[K] =
    ## CONSUMER/owner side: create shard0 (the well-known anchor) under key
    ## discipline `K` and register this process as the live consumer. Pass
    ## `path0` to producers via `REPRO_MONITOR_DEP_SHM`. `appId` tags the chain
    ## so only THIS app's reaper considers it (see `reapStaleSegments`); it must
    ## satisfy `validAppId`. `shard0Cap` MUST be a power of two.
    ##
    ## `runId` is the chain's identity and is written into shard0's HEADER, not
    ## into any file name (see `shardBasePrefix`). It must satisfy `validRunId`;
    ## it is otherwise unconstrained, and two chains of one app may share a runId
    ## without colliding on disk.
    mixin keyFormatVersion, extraControlWords
    result.available = false
    result.isConsumer = true
    result.producerSlot = -2
    result.producerPid = 0
    result.failure = afMissing
    result.dir = dir
    result.boot = bootId()
    if not validAppId(appId): return
    if not validRunId(runId): return
    if shard0Cap <= 0 or (shard0Cap and (shard0Cap - 1)) != 0: return
    try:
      if dir.len > 0: createDir(dir)
    except CatchableError: return
    # Claim an unused chain name. `chainSeq` carries no identity — it only keeps
    # the chains of one owner distinct, which the name no longer gets for free
    # from the runId. The `fileExists` retry also covers pid REUSE across a
    # crashed run on the same boot: previously an identically-named leftover was
    # silently overwritten by the rename below, taking its unreaped shards > 0
    # with it.
    var attempts = 0
    while true:
      let seqNo = atomicAddFetch(addr gChainSeq, 1'u64, ATOMIC_SEQ_CST)
      result.basePrefix = shardBasePrefix(dir, appId, seqNo, result.boot,
        uint64(getpid()))
      result.path0 = result.basePrefix & ".shard0"
      if not fileExists(result.path0): break
      inc attempts
      if attempts > 4096: return
    # Create shard0 via temp + atomic rename (a concurrent attacher never sees a
    # half-initialised file), with chainCount = 1.
    let extraWords = extraControlWords(K)
    let size = shardFileSize(shard0Cap, shard0ArenaCap, extraWords)
    if uint64(size) >= MaxShardBytes: return   # see `appendShardFile`
    inc result.tmpCtr
    let tmp = result.path0 & ".tmp." & $getpid()
    let tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600)
    if tfd < 0: return
    if ftruncate(tfd, Off(size)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return
    let base = mapFd(tfd, size)
    if base.isNil:
      discard close(tfd); discard unlink(tmp.cstring); return
    # Generation 1 is the first live generation (0 is `GenerationNone`, the
    # value every un-stamped word already holds).
    initShardHeader(base, 0, shard0Cap, shard0ArenaCap, result.boot, 1,
      keyFormatVersion(K), extraWords, 1'u64, runId)
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
    result.failure = afNone
    result.available = true

  proc createSet*(dir, appId, runId: string; shard0Cap = 1024;
      shard0ArenaCap = 256 * 1024): ShmGSet =
    ## `createSetT` at the default key discipline (key ≡ element) — io-mon's
    ## entry point, unchanged.
    createSetT(dir, appId, runId, IdentityKey, shard0Cap, shard0ArenaCap)

  # --- producer registry (the quiescence evidence `reset` needs) -------------
  #
  # `reset` is sound ONLY if no producer can be mid-insert, and the natural
  # quiescence point ("the monitored tree exited") is exactly the thing the §4.1
  # incident showed cannot be assumed: a detached descendant outlived its root
  # and kept producing. So the chain carries its own evidence — every producer
  # records its pid in shard0's registry on attach and clears it on detach, and
  # `reset` refuses while any registered pid is still ALIVE.
  #
  # A producer that dies without detaching leaves a dead pid behind; that is
  # reclaimed (CAS to 0) by whoever next scans, so a crash does not make the
  # chain permanently unrecyclable. Pid REUSE can only make the scan see a live
  # pid that is not really a producer, i.e. it can only cause a spurious
  # REFUSAL — the conservative direction.
  #
  # The registry is bounded (`MaxRegisteredProducers`). A producer that finds it
  # full still attaches — never fail a producer for a bookkeeping reason — but
  # counts itself in `ShOffProducerOverflow`, and `reset` refuses while that is
  # nonzero. Refusing costs the recycling optimisation; it never costs
  # correctness.

  proc pidAlive(pid: uint64): bool =
    if pid == 0: return false
    if kill(Pid(pid), cint(0)) == 0: return true
    errno != ESRCH

  proc reclaimDeadProducers(base: ShmBase) =
    ## CAS-clear registry entries whose pid is gone. Called only when the table
    ## looks full, so the ordinary attach path stays a short scan.
    for i in 0 ..< MaxRegisteredProducers:
      let off = ShOffProducers + i * 8
      var pid = loadU64Acquire(base, off)
      if pid == 0'u64 or pidAlive(pid): continue
      discard casU64(base, off, pid, 0'u64)

  proc registerProducer(base: ShmBase): int =
    ## Claim a registry entry for this process. Returns the index, or -1 when the
    ## registry is full (the caller is then counted in the overflow word).
    ## The claim is SEQ_CST — see `loadU64Seq` and `reset`.
    let me = uint64(getpid())
    let start = int(me mod uint64(MaxRegisteredProducers))
    for attempt in 0 .. 1:
      for i in 0 ..< MaxRegisteredProducers:
        let idx = (start + i) mod MaxRegisteredProducers
        let off = ShOffProducers + idx * 8
        var expected = 0'u64
        if casU64Seq(base, off, expected, me): return idx
      if attempt == 0: reclaimDeadProducers(base)
    discard fetchAddU64(base, ShOffProducerOverflow, 1)
    -1

  proc unregisterProducer(base: ShmBase; slot: int; ownerPid: uint64) =
    ## Release a registry entry, but ONLY this process's own.
    ##
    ## FORK SAFETY, and it is not theoretical: io-mon's shim installs an atfork
    ## handler (`discardDepQueueAfterFork`) that detaches the inherited producer
    ## in the CHILD and re-attaches under the child's own pid. The child's handle
    ## is a copy of the parent's, so it names the PARENT's registry slot; an
    ## unconditional clear there would deregister a parent that is still alive
    ## and producing, and `reset` would then see a quiescent chain that is not
    ## quiescent — the cardinal sin, arrived at through the very mechanism that
    ## exists to make forking safe. Comparing `ownerPid` against the caller's pid
    ## makes the release a no-op in the child, which then registers itself.
    let me = uint64(getpid())
    if ownerPid != me: return                 # an inherited handle: not ours
    if slot >= 0 and slot < MaxRegisteredProducers:
      var expected = ownerPid
      discard casU64(base, ShOffProducers + slot * 8, expected, 0'u64)
    elif slot == -1:
      var cur = loadU64Acquire(base, ShOffProducerOverflow)
      while cur > 0'u64:
        if casU64(base, ShOffProducerOverflow, cur, cur - 1): break

  proc liveProducerCounts(base: ShmBase;
      reclaim: bool): tuple[tracked, untracked: int] =
    ## Producers that could still be mid-insert, split by whether the chain
    ## KNOWS about them:
    ##
    ## - `tracked`   — registry entries whose pid is alive. Transient: they go
    ##   away when those processes exit, so a refusal on this count clears.
    ## - `untracked` — producers that attached when the registry was full. The
    ##   chain never learned their pids, so if one of them DIES without
    ##   detaching this count never falls again and the chain can never be
    ##   recycled. Refusing is still the right answer (it costs the optimisation,
    ##   never correctness), but it is a different situation from a busy chain
    ##   and `reset` reports it as one (`rsProducersUntracked`) rather than
    ##   letting a chain quietly stop recycling forever.
    ##
    ## Dead tracked entries are reclaimed on the way through when `reclaim` is
    ## set, so an ordinary producer crash does not wedge recycling at all.
    ##
    ## The registry loads are SEQ_CST so that this scan, paired with the seal
    ## store that precedes it in `reset`, cannot miss a concurrent registration
    ## that also missed the seal — see `loadU64Seq`.
    result.untracked = int(loadU64Acquire(base, ShOffProducerOverflow))
    for i in 0 ..< MaxRegisteredProducers:
      let off = ShOffProducers + i * 8
      var pid = loadU64Seq(base, off)
      if pid == 0'u64: continue
      if pidAlive(pid):
        inc result.tracked
      elif reclaim:
        discard casU64(base, off, pid, 0'u64)

  proc liveProducerCount(base: ShmBase; reclaim: bool): int =
    let c = liveProducerCounts(base, reclaim)
    c.tracked + c.untracked

  const AttachSealSpins = 4096
    ## How long an attach waits out an in-progress reset before giving up. A
    ## reset is a handful of stores, so the wait is microseconds; the bound
    ## exists only so a host that DIED mid-reset (leaving the seal set) cannot
    ## hang every producer forever.

  proc attachSetT*[K](path0: string; keyPolicy: typedesc[K]): ShmGSetT[K] =
    ## PRODUCER side: attach to a consumer-created chain via shard0's path.
    ## Returns an unavailable set (LF-2: caller fails fast, never spills) when
    ## the file is missing / wrong / stale (boot guard), when the chain was
    ## written under a DIFFERENT key discipline, or when it was written under a
    ## different HEADER LAYOUT REVISION. Those are not the same fault and are no
    ## longer reported as if they were: `attachFailure` names which one it was,
    ## and `afLayoutSkew` in particular is a build/deploy error rather than a
    ## runtime condition.
    ##
    ## A successful attach REGISTERS this process in shard0's producer registry,
    ## which is the evidence `reset` uses to refuse recycling while a producer
    ## could be mid-insert. `detach` deregisters. See the registry comment above.
    result.available = false
    result.isConsumer = false
    result.producerSlot = -2
    result.producerPid = 0
    result.failure = afBadPath
    if not path0.endsWith(".shard0"): return
    result.failure = afMissing
    result.path0 = path0
    result.basePrefix = path0[0 ..< path0.len - ".shard0".len]
    result.dir = parentDir(path0)
    result.boot = bootId()
    if not openShard(result, 0): return
    let b = result.shards[0].base
    # REGISTER, THEN RE-CHECK THE SEAL. This is the second half of the
    # store-buffer handshake described on `loadU64Seq`: `reset` stores the seal
    # and then scans the registry, so between the two of us at least one side
    # sees the other. Either reset's scan observes this registration and refuses
    # to recycle, or this load observes the seal and backs the attach out. The
    # outcome "reset believes the chain is quiescent while a producer believes
    # it attached cleanly" — which would put this producer's bytes into the NEXT
    # action's set — is the one both orderings forbid.
    #
    # Backing out is the conservative direction: a producer that shows up in the
    # microseconds a reset takes belongs to the action that just ENDED, and its
    # evidence has already been read. It waits first (`AttachSealSpins`), so a
    # producer of the NEXT action that raced the reset attaches to the new
    # generation rather than losing its evidence.
    var spins = 0
    while true:
      if loadU64Seq(b, ShOffResetSeal) == 0'u64:
        let slot = registerProducer(b)
        if loadU64Seq(b, ShOffResetSeal) == 0'u64:
          result.producerSlot = slot
          result.producerPid = uint64(getpid())
          break
        unregisterProducer(b, slot, uint64(getpid()))
      inc spins
      if spins > AttachSealSpins:
        result.failure = afRecycling
        result.shards[0].base = nil
        discard munmap(cast[pointer](b), result.shards[0].size)
        result.shards.setLen(0)
        return
      discard sched_yield()
    bumpGenStamped(b, ShOffProducerAttaches, headerGeneration(b), 1)
    result.failure = afNone
    result.available = true

  proc attachSet*(path0: string): ShmGSet =
    ## `attachSetT` at the default key discipline — io-mon's entry point,
    ## unchanged.
    attachSetT(path0, IdentityKey)

  proc attachFailure*[K](s: ShmGSetT[K]): AttachFailure =
    ## WHY this view is unavailable — `afNone` when it is not. See
    ## `AttachFailure`; `afLayoutSkew` is the version-skew diagnostic.
    if s.available: afNone else: s.failure

  proc detach*[K](s: var ShmGSetT[K]) =
    if s.producerSlot != -2 and s.shards.len > 0 and not s.shards[0].base.isNil:
      unregisterProducer(s.shards[0].base, s.producerSlot, s.producerPid)
    s.producerSlot = -2
    s.producerPid = 0
    for sm in s.shards.mitems:
      if not sm.base.isNil:
        discard munmap(cast[pointer](sm.base), sm.size)
        sm.base = nil
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
    # ONE generation read per insert, used for the stamp, the emptiness test and
    # every counter this call touches — see `currentGeneration` for why it is
    # re-read here rather than cached on the handle.
    let gen = currentGeneration(s)
    if gen == GenerationNone: return isUnavailable
    while true:
      let n = chainCount(s)
      let newestIdx = n - 1
      if not openShard(s, newestIdx): return isSaturated
      case insertIntoShard(K, s.shards[newestIdx], blob, keyHash, ifp, gen)
      of siInserted:
        if shouldGrow(s.shards[newestIdx], gen) and chainCount(s) == n:
          discard growNewest(s, n, s.shards[newestIdx], gen)
        return isInserted
      of siExists:
        return isExists
      of siNeedGrow:
        if not growNewest(s, n, s.shards[newestIdx], gen):
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
    let gen = currentGeneration(s)
    if gen == GenerationNone: return false
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
        if not slotIsLive(entry, gen): break
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
      let gen = currentGeneration(s)
      var k = 0
      while gen != GenerationNone and k < chainCount(s):
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
          if not slotIsLive(entry, gen): break  # end of the run
          let off = slotEntryOff(entry)
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
      let gen = currentGeneration(s)
      let sm = s.shards[k]
      for idx in 0 ..< sm.cap:
        let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
        if not slotIsLive(entry, gen): continue
        let off = slotEntryOff(entry)
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
      let gen = currentGeneration(s)
      let maxK = discoverMaxShard(s)
      for k in 0 .. maxK:
        if not openShard(s, k, patient = false): continue
        let sm = s.shards[k]
        if sm.isDrained: continue
        for idx in 0 ..< sm.cap:
          let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
          if not slotIsLive(entry, gen): continue
          let off = slotEntryOff(entry)
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
    let gen = currentGeneration(s)
    let maxK = discoverMaxShard(s)
    for k in 0 .. maxK:
      if openShard(s, k, patient = false):
        result += genStampedValue(
          loadU64Relaxed(s.shards[k].base, ShOffOccupied), gen)

  proc growthFailures*[K](s: var ShmGSetT[K]): uint64 =
    ## SIGNALLED saturation count (OOM growth failures) FOR THE CURRENT
    ## GENERATION. Nonzero ⇒ the consumer surfaces `mcIncomplete`; it is NEVER a
    ## silent drop. A recycled chain does not inherit the previous action's
    ## saturation — it starts empty with all its shards already grown, so the
    ## condition that produced it is gone.
    if not s.available or s.shards.len == 0: return 0
    genStampedValue(loadU64Relaxed(s.shards[0].base, ShOffGrowthFailed),
      currentGeneration(s))

  proc markConsumerGone*[K](s: var ShmGSetT[K]) =
    ## Announce that the consumer is no longer reading, so a late producer's
    ## `emit` fast-fails (LF-4) instead of writing into an orphan. NOT terminal
    ## any more: `reset` re-arms the token as part of recycling the chain.
    if s.available and s.shards.len > 0 and not s.shards[0].base.isNil:
      storeU64Release(s.shards[0].base, ShOffConsumerAlive, 0)

  proc runId*[K](s: ShmGSetT[K]): string =
    ## The chain's RUN IDENTITY, read from shard0's header. Available to a
    ## producer that only ever saw `path0` as well as to the owner, and it is the
    ## single source of truth: no caller (the reaper included) may re-derive it
    ## from a file name, which is what lets a chain be recycled and re-stamped
    ## without renaming a file.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return ""
    headerRunId(s.shards[0].base)

  proc consumerAlive*[K](s: ShmGSetT[K]): bool =
    ## Whether the host/consumer that owns shard0 is still registered as live
    ## (LF-4). The producer interface (`transport`) surfaces this as
    ## `emConsumerGone` so a monitored process learns to stop writing to an
    ## orphaned segment instead of silently accumulating unread state.
    ##
    ## ORDERING — the generation is acquire-loaded FIRST, deliberately, and the
    ## liveness token only after it. `reset` re-arms the token and THEN
    ## release-stores the generation, so this acquire synchronises-with that
    ## release and makes the re-armed token visible to anything that follows.
    ## The guarantee it buys is exactly the one the recycled chain needs: *the
    ## liveness token is never observable as GONE under the current generation*.
    ## Without the ordering, a producer attaching to a freshly recycled chain
    ## could observe the pre-reset `gone` and fast-fail with `emConsumerGone` —
    ## monitored by nobody, and silently.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return false
    let b = s.shards[0].base
    if headerGeneration(b) == GenerationNone: return false
    loadU64Acquire(b, ShOffConsumerAlive) != 0'u64

  # --- generation / recycling ------------------------------------------------

  proc generation*[K](s: ShmGSetT[K]): uint64 =
    ## The chain's current generation (1 for a freshly created chain, one more
    ## per successful `reset`). Every slot and counter stamped with any other
    ## value reads as empty.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil:
      return GenerationNone
    headerGeneration(s.shards[0].base)

  proc attachedProducers*[K](s: ShmGSetT[K]): int =
    ## How many producers could still be mid-insert: registry entries whose pid
    ## is ALIVE, plus any that could not be registered. This is the predicate
    ## `reset` refuses on, exposed so a caller can ask before trying (and so the
    ## refusal is testable as an observable fact rather than as a comment).
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return 0
    liveProducerCount(s.shards[0].base, reclaim = false)

  proc untrackedProducers*[K](s: ShmGSetT[K]): int =
    ## Of those, how many the chain could NOT record a pid for because the
    ## registry was full. Nonzero is what turns a refusal from transient
    ## (`rsBusyProducers`) into possibly permanent (`rsProducersUntracked`).
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return 0
    liveProducerCounts(s.shards[0].base, reclaim = false).untracked

  proc producerAttaches*[K](s: ShmGSetT[K]): uint64 =
    ## How many producers have successfully attached to this chain UNDER THE
    ## CURRENT GENERATION (reset to 0 by recycling, like every other counter).
    ##
    ## This is the host-side half of the version-skew diagnostic. A producer
    ## built against a different header layout revision cannot attach, and it
    ## cannot report anything into a file whose shape it does not know — so the
    ## host would otherwise see only an empty dependency set, indistinguishable
    ## from "the action genuinely touched nothing". With this counter the two
    ## separate: *elements == 0 AND producerAttaches == 0*, for an action that
    ## definitely spawned processes, is the fingerprint of a skewed (or
    ## un-injected) producer, whereas *elements == 0 AND producerAttaches > 0*
    ## means the producers really did attach and really did observe nothing.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil: return 0
    genStampedValue(loadU64Acquire(s.shards[0].base, ShOffProducerAttaches),
      headerGeneration(s.shards[0].base))

  proc shardLayoutRevision*(path: string): int =
    ## The header layout revision of any file, or -1 if it was not written by
    ## this library at all. Reads eight bytes at offset 0 and trusts nothing
    ## else, because the magic word's position and its frozen high bytes
    ## (`ShmGSetMagicBase`) are the ONLY things guaranteed to be common across
    ## revisions.
    ##
    ## This is the operator-facing half of the version-skew diagnostic: given a
    ## `path0` that a producer refused, anyone — the host, a test, a human — can
    ## compare this against `ShmGSetLayoutRevision` and get "the chain is
    ## revision 2, this build speaks revision 3" instead of an empty set.
    result = -1
    let fd = open(path.cstring, O_RDONLY)
    if fd < 0: return
    var buf: array[8, byte]
    var got = 0
    while got < 8:
      let n = read(fd, addr buf[got], 8 - got)
      if n <= 0: break
      got += n
    discard close(fd)
    if got < 8: return
    var magic: uint64
    copyMem(addr magic, addr buf[0], 8)
    if (magic and MagicRevisionMask) != ShmGSetMagicBase: return
    result = int(magic and not MagicRevisionMask)

  when defined(shmGSetScheduleHooks):
    proc forceGenerationForTest*[K](s: var ShmGSetT[K]; g: uint64) =
      ## TEST-ONLY seam (`-d:shmGSetScheduleHooks`, like `setForcedNextMapBase`):
      ## drive the chain's generation counter directly, so the once-per-4.29e9
      ## exhaustion path is reachable in a test instead of being reasoned about.
      if s.available and s.shards.len > 0 and not s.shards[0].base.isNil:
        storeU64Release(s.shards[0].base, ShOffGeneration, g)

  proc reset*[K](s: var ShmGSetT[K]; runId: string): ResetStatus =
    ## Recycle this chain into a FRESH, EMPTY set that keeps every shard it has
    ## already grown, and re-stamp it with `runId`. Consumer-only. O(1) at any
    ## chain size. See `ResetStatus` for the refusals.
    ##
    ## WHY IT REFUSES. Reset is sound only if no producer can be mid-insert. A
    ## producer sitting between its arena reserve and its slot publish when the
    ## generation flips would land bytes in the recycled set and they would be
    ## attributed to the NEXT action — a wrong dependency set, the cardinal sin.
    ## "The monitored tree exited" is the natural quiescence point but it is
    ## exactly what the §4.1 incident showed cannot be assumed, so this checks
    ## the chain's own producer registry and returns `rsBusyProducers` rather
    ## than trusting the caller's lifecycle.
    ##
    ## Checking quiescence is not enough on its own: a producer could attach in
    ## the window BETWEEN the check and the commit and then insert under the new
    ## generation, putting the finished action's bytes into the next one's set.
    ## So the check is bracketed by a SEAL. Reset stores the seal and then scans
    ## the registry; an attaching producer claims its registry entry and then
    ## reads the seal. Both pairs are sequentially consistent, which is exactly
    ## what forbids "neither side sees the other" (see `loadU64Seq`) — the
    ## producer either shows up in the scan, and the reset refuses, or it sees
    ## the seal and backs out.
    ##
    ## ORDER OF OPERATIONS — everything is written BEFORE the generation store,
    ## which is the single release-published commit point:
    ##
    ##   0. the seal, then the quiescence scan (above);
    ##   1. the new identity, into the runId slot the NEXT generation selects
    ##      (never the one the current generation is reading);
    ##   2. the consumer-liveness token, RE-ARMED — `markConsumerGone` is not
    ##      terminal any more. A producer that attaches to the new generation
    ##      must never observe a dead consumer and fast-fail with
    ##      `emConsumerGone`; `consumerAlive` reads the generation first with an
    ##      acquire, so observing the new generation implies observing the
    ##      re-armed token;
    ##   3. the generation itself, one release store. A crash BEFORE it leaves
    ##      the chain fully-old — old generation, old identity, old contents,
    ##      every shard file still linked. A crash after it leaves it fully-new.
    ##      There is no half-reset state, because nothing else changed. The seal
    ##      is dropped last, and a host that dies still holding it only makes
    ##      producers back off from a chain whose owner is gone.
    ##
    ## Nothing is zeroed. The slot tables and arenas of every shard keep their
    ## bytes; they are unreachable under the new generation, and the arena bump
    ## pointers rebase themselves on first use (`reserveArena`). That is what
    ## makes the cost independent of what the chain grew to.
    if not s.available or s.shards.len == 0 or s.shards[0].base.isNil:
      return rsUnavailable
    if not s.isConsumer: return rsNotConsumer
    if not validRunId(runId): return rsInvalidRunId
    let b = s.shards[0].base
    let cur = headerGeneration(b)
    if cur == GenerationNone: return rsUnavailable
    if cur >= MaxGeneration: return rsGenerationExhausted
    storeU64Seq(b, ShOffResetSeal, 1'u64)
    let live = liveProducerCounts(b, reclaim = true)
    if live.tracked > 0 or live.untracked > 0:
      storeU64Seq(b, ShOffResetSeal, 0'u64)
      return (if live.tracked > 0: rsBusyProducers else: rsProducersUntracked)
    let next = cur + 1
    scheduleHook(spBeforeRunIdStamp)
    writeRunIdSlot(b, next, runId)
    scheduleHook(spBeforeLivenessRearm)
    storeU64Relaxed(b, ShOffConsumerBoot, s.boot)
    storeU64Relaxed(b, ShOffConsumerPid, uint64(getpid()))
    storeU64Release(b, ShOffConsumerAlive, 1)
    scheduleHook(spBeforeGenerationPublish)
    storeU64Release(b, ShOffGeneration, next)   # COMMIT
    scheduleHook(spAfterGenerationPublish)
    storeU64Seq(b, ShOffResetSeal, 0'u64)
    rsReset

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
    let gen = currentGeneration(s)
    let maxK = discoverMaxShard(s)
    for k in 0 .. maxK:
      if not openShard(s, k, patient = false): continue
      let sm = s.shards[k]
      let lo = cast[uint](sm.base)
      let hi = lo + uint(sm.size)
      for idx in 0 ..< sm.cap:
        let entry = loadU64Acquire(sm.base, sm.slotsOff + idx * SlotSize)
        if not slotIsLive(entry, gen): continue
        let off = uint64(slotEntryOff(entry))
        doAssert off < uint64(sm.size),
          "slot entry " & $off & " is not an in-shard offset (>= size " &
          $sm.size & "): absolute-pointer leak"
        let a = uint(off)
        doAssert not (a >= lo and a < hi),
          "stored slot value falls inside the mapping window: absolute pointer"
        let rlen = int(loadU32Acquire(sm.base, int(off) + ArenaRecLen))
        doAssert int(off) + ArenaRecHdr + rlen <= sm.size,
          "arena record overruns the shard (torn/corrupt offset)"

  proc shards0Base*[K](s: ShmGSetT[K]): pointer =
    ## The mapped base address of shard0 in THIS process (for the
    ## position-independence test, which asserts two processes/mappings observe
    ## the same set at DIFFERENT bases — no absolute pointer may live in the
    ## segment). Returns nil if unmapped.
    if s.shards.len > 0: cast[pointer](s.shards[0].base) else: nil

  # --- reaper (cross-restart GC, design spec §4.3.4) ------------------------

  proc readAnchorRunId(anchor: string): tuple[fromHeader: bool; runId: string] =
    ## Read a chain's RUN IDENTITY out of shard0's header with a plain bounded
    ## `read` — nothing is mapped and no field is trusted. The reaper points this
    ## at whatever files it finds in a shared directory, which include legacy
    ## (pre-HM-1) chains, chains of another key discipline, truncated leftovers
    ## and files that are not shards at all, so every one of those must read as
    ## "no header identity" rather than as arbitrary bytes.
    ##
    ## The key-discipline version word is deliberately NOT checked: the runId
    ## field sits at a fixed offset in the shared header layout, so the reaper
    ## stays key-discipline agnostic and can attribute a chain written under any
    ## policy.
    result = (false, "")
    let fd = open(anchor.cstring, O_RDONLY)
    if fd < 0: return
    var buf: array[ShardHeaderSize, byte]
    var got = 0
    while got < ShardHeaderSize:
      let n = read(fd, addr buf[got], ShardHeaderSize - got)
      if n <= 0: break
      got += n
    discard close(fd)
    if got < ShardHeaderSize: return       # too small to carry a header
    var magic: uint64
    copyMem(addr magic, addr buf[ShOffMagic], 8)
    if magic != ShmGSetMagic: return       # legacy layout, or not a shard
    # The identity lives in the slot the CURRENT generation selects, so a chain
    # that has been RECYCLED reports the run it was re-stamped for, not the one
    # it was created for. Reading the wrong slot would report the previous
    # action's identity — the same misattribution the header move was for.
    var gen: uint64
    copyMem(addr gen, addr buf[ShOffGeneration], 8)
    if gen == GenerationNone: return       # never published: no identity
    let slot = ShOffRunIdSlots + int(gen and 1'u64) * RunIdSlotBytes
    var rawLen: uint32
    copyMem(addr rawLen, addr buf[slot], 4)
    let n = int(rawLen)
    if n > RunIdMaxBytes: return           # corrupt length: no identity
    result.fromHeader = true
    if n > 0:
      result.runId = newString(n)
      copyMem(addr result.runId[0], addr buf[slot + RunIdSlotHdr], n)

  proc reapStaleSegmentsDetailed*(dir, appId: string): seq[ReapedSegment] =
    ## `reapStaleSegments` with the ATTRIBUTION kept: one `ReapedSegment` per
    ## chain collected, in the order they were collected.
    ##
    ## Scoping and staleness come from the anchor NAME
    ## (`{appId}~{chainSeq}.{boot}.{pid}.shard0`), which is all the name carries.
    ## IDENTITY comes from shard0's HEADER, read before anything is unlinked. The
    ## two are deliberately separate: a chain that is recycled and re-stamped
    ## keeps its name, so a name-derived runId would be stale, and a name-derived
    ## runId cannot exist at all for a current chain.
    ##
    ## Only anchors tagged with `appId` are considered; segments of any OTHER
    ## appId are IGNORED entirely — never reaped, never even liveness-checked —
    ## so one app cannot reap another's live/crashed segments and cross-app pid
    ## reuse cannot misfire. WITHIN the matching appId the staleness rule is
    ## unchanged: reap the whole chain when boot != currentBoot (survived a
    ## reboot ⇒ pids meaningless) OR the owner pid is dead on the current boot. A
    ## live-owner run is left alone. An `flock(LOCK_EX|LOCK_NB)` on shard0 guards
    ## a run that is just starting.
    ##
    ## MIGRATION: a chain written under the pre-HM-1 naming
    ## (`{appId}~{runId}.{boot}.{pid}`) has the same component SHAPE, so it is
    ## scoped, judged and COLLECTED by exactly this rule — never skipped and left
    ## to leak. It cannot be attached any more (its header magic is the old
    ## layout), so being collected once stale is the only outcome that does not
    ## leak it. Its `runIdFromHeader` is false and its `runId` is the one the old
    ## NAME carried, which is the only place a legacy chain has it.
    if not validAppId(appId): return @[]
    let cur = bootId()
    var anchors: seq[string]
    try:
      for _, p in walkDir(dir):
        if extractFilename(p).endsWith(".shard0"): anchors.add p
    except CatchableError: return @[]
    for anchor in anchors:
      let name = extractFilename(anchor)
      let stem = name[0 ..< name.len - ".shard0".len]  # appId~chainSeq.boot.pid
      let sep = stem.find(AppIdSep)                    # first '~' ends the appId
      if sep < 0: continue                             # untagged / foreign anchor
      if stem[0 ..< sep] != appId: continue            # another app: leave alone
      let rest = stem[sep + 1 .. ^1]                   # chainSeq.boot.pid
      let parts = rest.rsplit('.', 2)                  # [chainSeq, boot, pid]
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
      # Attribute BEFORE unlinking — the identity lives in the file.
      let ident = readAnchorRunId(anchor)
      var seg = ReapedSegment(anchor: anchor, boot: boot, ownerPid: pid,
        runIdFromHeader: ident.fromHeader,
        runId: (if ident.fromHeader: ident.runId else: parts[0]))
      let base = dir / stem                # dir/{appId}~{chainSeq}.{boot}.{pid}
      var k = 0
      while true:
        let sp = base & ".shard" & $k
        if not fileExists(sp): break
        try:
          removeFile(sp); inc seg.filesRemoved
        except CatchableError: discard
        inc k
      if fd >= 0: discard close(fd)
      result.add seg

  proc reapStaleSegments*(dir, appId: string): int =
    ## Cross-restart GC SCOPED TO ONE appId; returns the number of shard FILES
    ## removed. See `reapStaleSegmentsDetailed` for the rule and for the
    ## per-chain attribution.
    for seg in reapStaleSegmentsDetailed(dir, appId): result += seg.filesRemoved

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
  proc shardBasePrefix*(dir, appId: string;
      chainSeq, boot, ownerPid: uint64): string =
    dir & "/" & appId & "~" & $chainSeq & "." & $boot & "." & $ownerPid
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
  proc attachFailure*[K](s: ShmGSetT[K]): AttachFailure = afMissing
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
  proc runId*[K](s: ShmGSetT[K]): string = ""
  proc consumerAlive*[K](s: ShmGSetT[K]): bool = false
  proc generation*[K](s: ShmGSetT[K]): uint64 = GenerationNone
  proc attachedProducers*[K](s: ShmGSetT[K]): int = 0
  proc untrackedProducers*[K](s: ShmGSetT[K]): int = 0
  proc producerAttaches*[K](s: ShmGSetT[K]): uint64 = 0
  proc shardLayoutRevision*(path: string): int = -1
  proc reset*[K](s: var ShmGSetT[K]; runId: string): ResetStatus = rsUnavailable
  proc shardIsDrained*[K](s: var ShmGSetT[K]; k: int): bool = false
  proc markShardDrained*[K](s: var ShmGSetT[K]; k: int): bool {.discardable.} = false
  proc retireShard*[K](s: var ShmGSetT[K]; k: int): bool {.discardable.} = false
  proc assertNoAbsolutePointers*[K](s: var ShmGSetT[K]) = discard
  proc shards0Base*[K](s: ShmGSetT[K]): pointer = nil
  proc reapStaleSegmentsDetailed*(dir, appId: string): seq[ReapedSegment] = @[]
  proc reapStaleSegments*(dir, appId: string): int = 0
