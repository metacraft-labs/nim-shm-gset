## Reference model of the SECOND key discipline the parameterisation exists for:
## reprobuild's action-cache index (`reprobuild-specs/Action-Cache-Per-Edge-Store.md`
## §6.2–6.5). It lives in `tests/` on purpose — `shm_gset` stays domain-free; this
## is the consumer-side encoding the property suite exercises the structure with,
## and the shape reprobuild will lift when it integrates.
##
## NO MOCKS. Everything here is the real encoding over the real structure: real
## `mmap`-backed shards, real inserts, real probe-run walks. The only thing this
## module "models" is the *element codec and the liveness rule*, which are
## consumer concerns by design — the set stores opaque bytes.
##
## Element layout (spec §6.2):
##
##     off  size  field
##       0     4  magic "RBIE"
##       4     1  kind                 0 = record, 1 = edge-complete
##       5     1  flags                bit 0 = tombstone
##       6     1  weakAlgorithm
##       7     1  weakDomain
##       8     1  strongAlgorithm      0 when kind = 1
##       9     1  strongDomain         0 when kind = 1
##      10     2  reserved             must be 0
##      12     8  generation u64le
##      20    32  weakFingerprint
##      52    32  strongFingerprint    present only when kind = 0
##                84 bytes (kind = 0) / 52 bytes (kind = 1)
##
## THE THREE PROJECTIONS, for this discipline:
##   * stored    — all 84 (or 52) bytes;
##   * hashed    — bytes 20..51, the weak fingerprint ALONE, so every element of
##                 one edge shares a home slot and occupies one probe run;
##   * compared  — the whole element (identity + generation + tombstone flag), so
##                 a tombstone never dedups against the record it retires and two
##                 generations of one key coexist until a flatten.

import std/[tables]
import shm_gset

const
  AcMagic* = ['R'.byte, 'B'.byte, 'I'.byte, 'E'.byte]
  AcOffKind* = 4
  AcOffFlags* = 5
  AcOffWeakAlgo* = 6
  AcOffWeakDomain* = 7
  AcOffStrongAlgo* = 8
  AcOffStrongDomain* = 9
  AcOffGeneration* = 12
  AcOffWeakFp* = 20
  AcOffStrongFp* = 52
  AcRecordSize* = 84
  AcEdgeCompleteSize* = 52
  AcFlagTombstone* = 0x01'u8

  AcGenWord* = 0      ## extra control word 0: the GLOBAL generation counter
  AcBypassWord* = 1   ## extra control word 1: `bypassWrites` (spec §6.8)

type
  AcKind* = enum
    akRecord = 0
    akEdgeComplete = 1

  Fp32* = array[32, byte]

  AcIndexKey* = object
    ## The action-cache key discipline: key ≠ element. The primary hash is
    ## computed over the WEAK fingerprint alone (spec §6.3), so all elements of
    ## one edge land in one contiguous linear-probe run and enumeration of the
    ## edge is the walk from `h(weak)` to the first empty slot.

# --- policy hooks -----------------------------------------------------------

proc primaryKeySpan*(_: typedesc[AcIndexKey];
    blob: openArray[byte]): tuple[a, b: int] {.inline.} =
  ## The weak fingerprint, and ONLY the weak fingerprint. This is the whole
  ## multimap mechanism: `record` and `edge-complete` elements, live ones and
  ## tombstones, all hash to the same home slot for one edge.
  (AcOffWeakFp, AcOffWeakFp + 31)

proc keyFormatVersion*(_: typedesc[AcIndexKey]): uint32 {.inline.} = 2'u32
  ## A chain written under this discipline must never be attached under
  ## `IdentityKey` (or vice versa): the header check rejects it.

proc extraControlWords*(_: typedesc[AcIndexKey]): int {.inline.} = 2
  ## `AcGenWord` (spec §6.5: a single global u64 in shard0's control block, so
  ## "newer" is a total order across the whole chain) and `AcBypassWord`
  ## (spec §6.8).

# `hashKey`, `identityFp` and `identityEq` keep the library defaults on purpose:
#   * hashKey    — FNV-1a over the 32 key bytes;
#   * identityFp — FNV-1a over the WHOLE element, which is what keeps the
#                  fast-reject useful inside a run whose members all share a key;
#   * identityEq — byte equality, so an element differing only in its generation
#                  or its tombstone flag is a DIFFERENT element (required: a
#                  tombstone must not dedup against the record it retires).

# --- element codec ----------------------------------------------------------

proc fpOf*(seed: string): Fp32 =
  ## A deterministic 32-byte fingerprint from a label (stands in for a real
  ## content hash; the structure never interprets these bytes).
  var raw = newSeq[byte](seed.len)
  for i, c in seed: raw[i] = byte(c)
  var h = fingerprint(raw)
  for i in 0 ..< 32:
    h = (h xor uint64(i)) * 1099511628211'u64
    result[i] = byte(h shr 32)

proc putU64le(dst: var seq[byte]; off: int; v: uint64) =
  for i in 0 ..< 8: dst[off + i] = byte((v shr (8 * i)) and 0xFF'u64)

proc getU64le(src: openArray[byte]; off: int): uint64 =
  for i in 0 ..< 8: result = result or (uint64(src[off + i]) shl (8 * i))

proc acElement*(kind: AcKind; weak: Fp32; strong: Fp32; generation: uint64;
    tombstone = false; weakAlgo = 1'u8; weakDomain = 2'u8): seq[byte] =
  ## Encode one index element.
  result = newSeq[byte](
    if kind == akRecord: AcRecordSize else: AcEdgeCompleteSize)
  for i in 0 .. 3: result[i] = AcMagic[i]
  result[AcOffKind] = byte(ord(kind))
  result[AcOffFlags] = (if tombstone: AcFlagTombstone else: 0'u8)
  result[AcOffWeakAlgo] = weakAlgo
  result[AcOffWeakDomain] = weakDomain
  if kind == akRecord:
    result[AcOffStrongAlgo] = 1'u8
    result[AcOffStrongDomain] = 3'u8
  putU64le(result, AcOffGeneration, generation)
  for i in 0 ..< 32: result[AcOffWeakFp + i] = weak[i]
  if kind == akRecord:
    for i in 0 ..< 32: result[AcOffStrongFp + i] = strong[i]

proc acRecord*(weak, strong: Fp32; generation: uint64;
    tombstone = false): seq[byte] =
  acElement(akRecord, weak, strong, generation, tombstone)

proc acEdgeComplete*(weak: Fp32; generation: uint64;
    tombstone = false): seq[byte] =
  var zero: Fp32
  acElement(akEdgeComplete, weak, zero, generation, tombstone)

proc acKind*(e: openArray[byte]): AcKind = AcKind(e[AcOffKind])
proc acIsTombstone*(e: openArray[byte]): bool =
  (e[AcOffFlags] and AcFlagTombstone) != 0'u8
proc acGeneration*(e: openArray[byte]): uint64 = getU64le(e, AcOffGeneration)

proc acWeak*(e: openArray[byte]): Fp32 =
  for i in 0 ..< 32: result[i] = e[AcOffWeakFp + i]

proc acStrong*(e: openArray[byte]): Fp32 =
  if acKind(e) == akRecord:
    for i in 0 ..< 32: result[i] = e[AcOffStrongFp + i]

proc acIsWellFormed*(e: openArray[byte]): bool =
  e.len in {AcRecordSize, AcEdgeCompleteSize} and
    e[0] == AcMagic[0] and e[1] == AcMagic[1] and
    e[2] == AcMagic[2] and e[3] == AcMagic[3]

proc acIdentity*(e: openArray[byte]): string =
  ## The KEY identity `(kind, weak, strong)` of spec §6.4 — deliberately EXCLUDES
  ## the generation and the tombstone flag, because a tombstone retires the key
  ## its identity names.
  result = newStringOfCap(66)
  result.add char(e[AcOffKind])
  for i in 0 ..< 32: result.add char(e[AcOffWeakFp + i])
  if acKind(e) == akRecord:
    for i in 0 ..< 32: result.add char(e[AcOffStrongFp + i])

# --- liveness (spec §6.5) ---------------------------------------------------

type AcEdgeView* = object
  ## The result of enumerating one edge's probe run: for every key identity, the
  ## newest record generation and the newest tombstone generation seen.
  newestRecord*: Table[string, uint64]
  newestTombstone*: Table[string, uint64]
  seenForeign*: int      ## elements in the run belonging to another weak key
  visited*: int          ## slots walked (the run length)

proc observe*(v: var AcEdgeView; e: openArray[byte]) =
  let id = acIdentity(e)
  let g = acGeneration(e)
  if acIsTombstone(e):
    if id notin v.newestTombstone or v.newestTombstone[id] < g:
      v.newestTombstone[id] = g
  else:
    if id notin v.newestRecord or v.newestRecord[id] < g:
      v.newestRecord[id] = g

proc isLive*(v: AcEdgeView; id: string): bool =
  ## > A key is live iff no tombstone for it exists bearing a generation NEWER
  ## > than the newest `record` element for that key. (spec §6.5)
  ##
  ## "Newer" is strict, so a tombstone must be stamped with a STRICTLY greater
  ## generation than the record it retires — which is why `acEvict` allocates a
  ## fresh generation from the global counter instead of reusing the current one.
  if id notin v.newestRecord: return false
  let r = v.newestRecord[id]
  if id notin v.newestTombstone: return true
  v.newestTombstone[id] <= r

iterator liveIdentities*(v: AcEdgeView): string =
  for id in v.newestRecord.keys:
    if v.isLive(id): yield id

# --- operations over a real chain -------------------------------------------

proc acScanEdge*(s: var ShmGSetT[AcIndexKey]; weak: Fp32): AcEdgeView =
  ## Enumerate an edge: the probe-run walk from `h(weak)` to the first empty
  ## slot in every shard, filtering on the STORED weak fingerprint. This is the
  ## whole read path of spec §8 step 1 — mapped memory only, no syscall, and no
  ## heap allocation to reach the element bytes (the tables below are the
  ## caller's own bookkeeping).
  result.newestRecord = initTable[string, uint64]()
  result.newestTombstone = initTable[string, uint64]()
  for view in s.withPrimaryKey(weak):
    inc result.visited
    if not acIsWellFormed(view.bytes) or acWeak(view.bytes) != weak:
      inc result.seenForeign         # a foreign key sharing this run
      continue
    result.observe(view.bytes)

## GENERATION INVARIANT (what makes the strict liveness rule decidable):
##
##   every generation ever stamped into an element is <= the global counter.
##
## `acInsert` stamps with the counter's current value, or with
## `tombstoneGen + 1` and bumps the counter to match; `acEvict` allocates
## `fetchAdd(1) + 1`, which is therefore strictly greater than every generation
## stamped before it. That is what guarantees a tombstone actually retires the
## record it follows — the rule of §6.5 requires "newer", strictly.

proc acInsert*(s: var ShmGSetT[AcIndexKey]; kind: AcKind; weak, strong: Fp32):
    InsertStatus =
  ## Spec §6.4. (1) If a LIVE element with this identity is already present,
  ## return `isExists` and write NOTHING. (2) Otherwise stamp with
  ## `max(currentGeneration, supersedingTombstoneGeneration + 1)`, bumping the
  ## global counter if the second term wins, and claim a slot.
  let view = acScanEdge(s, weak)
  var probe = acElement(kind, weak, strong, 0)
  let id = acIdentity(probe)
  if view.isLive(id): return isExists
  var gen = s.controlWord(AcGenWord)
  if id in view.newestTombstone and view.newestTombstone[id] + 1 > gen:
    gen = view.newestTombstone[id] + 1
    discard s.controlWordBumpTo(AcGenWord, gen)
  let e = acElement(kind, weak, strong, gen)
  s.insert(e)

proc acEvict*(s: var ShmGSetT[AcIndexKey]; kind: AcKind;
    weak, strong: Fp32): InsertStatus =
  ## Spec §6.5. Eviction is an ORDINARY INSERT whose bytes are a pure function of
  ## the original element's identity, with the tombstone flag set, carrying a
  ## FRESHLY ALLOCATED generation — strictly newer than anything stamped before
  ## it, which is what makes the strict "newer than" of the liveness rule decide.
  let gen = s.controlWordFetchAdd(AcGenWord, 1) + 1
  s.insert(acElement(kind, weak, strong, gen, tombstone = true))

proc acLiveStrongs*(s: var ShmGSetT[AcIndexKey]; weak: Fp32): seq[string] =
  ## The live `record` keys of one edge (spec §8 step 1), as identity strings.
  let v = s.acScanEdge(weak)
  for id in v.liveIdentities:
    if id.len > 0 and id[0] == char(ord(akRecord)): result.add id

proc acEdgeIsComplete*(s: var ShmGSetT[AcIndexKey]; weak: Fp32): bool =
  ## Whether a live `edge-complete` element exists for this edge, honoured only
  ## when the chain's growth-failure and bypass counters are both zero
  ## (spec §8 step 2).
  if s.growthFailures() != 0: return false
  if s.controlWord(AcBypassWord) != 0: return false
  var zero: Fp32
  let want = acIdentity(acElement(akEdgeComplete, weak, zero, 0))
  s.acScanEdge(weak).isLive(want)
