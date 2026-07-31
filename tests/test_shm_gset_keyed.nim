## ALGORITHMIC PROPERTY SUITE for the parameterised key discipline.
##
## This suite validates the structure in ISOLATION — no consumer integration —
## against the properties both disciplines must deliver. Nothing here is mocked:
## every check runs against real `mmap`-backed shard files, the real lock-free
## slot-claim, and the real probe-run walk.
##
## What each section establishes:
##
##   A. IO-MON IS UNCHANGED — the default instantiation is `ShmGSetT[IdentityKey]`,
##      its home slot and stored fingerprint are the pre-parameterisation values
##      bit-for-bit, and a deterministic chain hashes to the SAME shard-file bytes
##      as the build that predates the parameterisation (golden digests below).
##      Also: the parameterisation does NOT degrade io-mon to a linear scan —
##      distinct elements still spread over distinct home slots and a walk is a
##      short cluster, not the table.
##   B. PROBE-RUN COMPLETENESS — every element sharing a primary key is reachable
##      from its home slot before the first empty slot, including when the run is
##      interleaved with foreign keys and when it is split across shards. Checked
##      EXHAUSTIVELY: every element of a large population is re-found by a walk.
##   C. IDEMPOTENCE AND CONVERGENCE — re-insert writes nothing; the union is
##      order-independent across writers and shards.
##   D. TOMBSTONE SEMANTICS — a key is live iff no tombstone for it bears a
##      strictly newer generation; a tombstone never resurrects and never hides a
##      different key (not even one sharing its probe run); the decision is
##      independent of insertion order and of which shard each element landed in.
##   E. NO HEAP ALLOCATION ON THE INSERT PATH — counted as alloc/dealloc EVENTS
##      (`-d:nimAllocStats`), not as residency, so a transient buffer that is
##      freed before the measurement ends cannot hide. Both disciplines.
##   F. POLICY ISOLATION — a chain written under one discipline cannot be
##      attached under another.
##   G. FLATTEN AND RETIRE — copy-forward then drain then unlink never makes an
##      observable element unobservable.

import std/[algorithm, os, posix, random, sets, sha1, strutils, tables, unittest]
import shm_gset
import ac_index_model

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-keyed-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result)
  createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc hexOf(b: openArray[byte]): string =
  result = newStringOfCap(b.len * 2)
  for x in b: result.add toHex(x.int, 2)

proc hexOf(b: Fp32): string = hexOf(b.toOpenArray(0, 31))

# ---------------------------------------------------------------------------
# A. io-mon (IdentityKey) is unchanged
# ---------------------------------------------------------------------------

suite "A. the identity instantiation is bit-for-bit the pre-existing structure":

  test "A1 ShmGSet IS the identity instantiation (no separate code path)":
    static: doAssert ShmGSet is ShmGSetT[IdentityKey]

  test "A2 placement and stored fingerprint are the pre-parameterisation values":
    # Before the split there was one value: `fingerprint(blob) or 1`, used BOTH
    # as the home-slot source and as the arena record's fingerprint. Under
    # IdentityKey the three projections collapse back onto exactly that value —
    # and it is computed ONCE per insert (identityFp returns the key hash).
    let dir = freshDir("ident")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 256, shard0ArenaCap = 65536)
    check s.available
    for i in 0 ..< 500:
      let blob = bytesOf("elem-" & $i)
      check s.elementKeyHash(blob) == (fingerprint(blob) or 1'u64)
      check identityFp(IdentityKey, blob, s.elementKeyHash(blob)) ==
        (fingerprint(blob) or 1'u64)
    check s.elementKeyHash(newSeq[byte](0)) ==
      (fingerprint(newSeq[byte](0)) or 1'u64)      # the empty element too
    s.detach()

  test "A3 the on-disk shard bytes are UNCHANGED (golden digests)":
    # Digests captured by running this exact insert sequence against the build
    # that predates the parameterisation. Only the three host-varying header
    # fields are masked (creator boot id, consumer pid, consumer boot);
    # everything else — every header field value, the whole slot array, every
    # arena byte, the file sizes, the shard COUNT — is compared.
    #
    # If a future change to the key discipline forces io-mon's format to move,
    # this test fails, which is the intended alarm.
    const golden = [
      (4096,   "edad141e54d89507cfaf2316094eec6ade60c99d"),
      (12288,  "823750a7181057f98043669fa102eb29086dbc64"),
      (45056,  "e6c911ad15acb097847bd4d53c23c8d394f9c889"),
      (167936, "38f2b50c285af9201b40180947c62ab7abb0fd3f")]
    let dir = freshDir("golden")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "goldenEdge", shard0Cap = 64,
      shard0ArenaCap = 2048)
    check s.available
    for i in 0 ..< 2000:
      check s.insert(bytesOf("path/to/file-" & $i & ".h")) in {isInserted, isExists}
    check s.insert(newSeq[byte](0)) in {isInserted, isExists}
    check s.shardCount() == golden.len
    let prefix = s.path0[0 ..< s.path0.len - ".shard0".len]
    for k in 0 ..< golden.len:
      var data = readFile(prefix & ".shard" & $k)
      for i in 16 ..< 24: data[i] = '\0'       # creatorBootId
      for i in 96 ..< 112: data[i] = '\0'      # consumerPid, consumerBoot
      check (data.len, toLowerAscii($secureHash(data))) == golden[k]
    s.detach()

  test "A4 identity keys still SPREAD — no silent degradation to a linear scan":
    # The failure mode a parameterisation could introduce is a primary hash that
    # collapses distinct elements onto one home slot, turning every probe into a
    # scan. Assert the opposite for IdentityKey: distinct elements occupy
    # (nearly) distinct home slots, and a lookup walk is a SHORT CLUSTER — a
    # small constant, not O(capacity).
    let dir = freshDir("spread")
    defer: removeDir(dir)
    const cap = 4096
    var s = createSetT(dir, "io-mon", "edge", IdentityKey,
      shard0Cap = cap, shard0ArenaCap = 1 shl 20)
    check s.available
    var homes = initHashSet[uint64]()
    var elems: seq[seq[byte]]
    for i in 0 ..< 1000:                      # load factor 0.24, below the grow
      let blob = bytesOf("dep/path/number-" & $i & ".h")
      elems.add blob
      homes.incl(s.elementKeyHash(blob) and uint64(cap - 1))
      check s.insert(blob) == isInserted
    check s.shardCount() == 1                 # no growth: one table to measure
    # 1000 elements over 4096 slots: the birthday-collision expectation is ~885
    # distinct home slots. Anything near 1 would be the degenerate case.
    check homes.len > 800
    var worst = 0
    var total = 0
    for blob in elems:
      var visited = 0
      for _ in s.withPrimaryKey(blob): inc visited
      worst = max(worst, visited)
      total += visited
    check worst < 40                          # cluster, not table (cap = 4096)
    check total div elems.len <= 3            # mean walk is a handful of slots
    s.detach()

# ---------------------------------------------------------------------------
# B. probe-run completeness (the multimap without a stored chain)
# ---------------------------------------------------------------------------

proc weakHome(w: Fp32; cap: int): uint64 =
  (fingerprint(w.toOpenArray(0, 31)) or 1'u64) and uint64(cap - 1)

proc collidingWeaks(cap, n: int): seq[Fp32] =
  ## `n` DISTINCT weak fingerprints that share one home slot, so their probe runs
  ## are forced to interleave in the same cluster.
  var byHome = initTable[uint64, seq[Fp32]]()
  var i = 0
  while true:
    let w = fpOf("weak-collide-" & $i)
    let h = weakHome(w, cap)
    byHome.mgetOrPut(h, @[]).add w
    if byHome[h].len == n: return byHome[h]
    inc i
    doAssert i < 5_000_000, "no colliding weak set found"

suite "B. probe-run completeness: the run IS the enumeration":

  test "B1 every element of an edge is reachable before the first empty slot":
    let dir = freshDir("run")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 1024, shard0ArenaCap = 1 shl 20)
    check s.available
    let weak = fpOf("edge-A")
    var expected = initHashSet[string]()
    for j in 0 ..< 24:                        # 24 path-sets on ONE edge
      let e = acRecord(weak, fpOf("strong-" & $j), 0)
      check s.insert(e) == isInserted
      expected.incl hexOf(e)
    let ec = acEdgeComplete(weak, 0)
    check s.insert(ec) == isInserted
    expected.incl hexOf(ec)

    var got = initHashSet[string]()
    var visited = 0
    for v in s.withPrimaryKey(weak):
      inc visited
      if acIsWellFormed(v.bytes) and acWeak(v.bytes) == weak:
        got.incl hexOf(v.bytes)
    check got == expected                     # all 25, from ONE home slot walk
    check visited >= 25
    # No stored chain was needed: the run is contiguous from the home slot.
    check visited <= 40
    s.detach()

  test "B2 a run interleaved with FOREIGN keys is still complete":
    # Three distinct weak fingerprints deliberately share a home slot. Their
    # elements interleave in one cluster; each edge's walk must still yield
    # exactly its own elements, paying one comparison per foreign element.
    let dir = freshDir("interleave")
    defer: removeDir(dir)
    const cap = 1024
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = cap, shard0ArenaCap = 1 shl 20)
    check s.available
    let weaks = collidingWeaks(cap, 3)
    check weakHome(weaks[0], cap) == weakHome(weaks[1], cap)
    check weakHome(weaks[1], cap) == weakHome(weaks[2], cap)
    var expected: array[3, HashSet[string]]
    for r in 0 ..< 3:
      expected[r] = initHashSet[string]()
    # Interleave the inserts so no edge occupies a contiguous prefix by luck.
    for j in 0 ..< 12:
      for w in 0 ..< 3:
        let e = acRecord(weaks[w], fpOf("s-" & $w & "-" & $j), 0)
        check s.insert(e) == isInserted
        expected[w].incl hexOf(e)
    for w in 0 ..< 3:
      var got = initHashSet[string]()
      var foreign = 0
      for v in s.withPrimaryKey(weaks[w]):
        if acWeak(v.bytes) == weaks[w]: got.incl hexOf(v.bytes)
        else: inc foreign
      check got == expected[w]                # complete
      check foreign > 0                       # and genuinely interleaved
    s.detach()

  test "B3 EXHAUSTIVE: every element in a multi-shard chain is re-found":
    # The strongest formulation of "no early termination": build a large
    # population over many edges, force several shards, then for EVERY inserted
    # element assert the walk for its own primary key yields it.
    let dir = freshDir("exhaustive")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 64, shard0ArenaCap = 4096)   # tiny: forces heavy sharding
    check s.available
    var byWeak = initTable[string, HashSet[string]]()
    var weaks: seq[Fp32]
    for i in 0 ..< 300:
      let w = fpOf("edge-" & $i)
      weaks.add w
      byWeak[hexOf(w)] = initHashSet[string]()
      for j in 0 .. (i mod 4):                # 1..4 path-sets per edge
        let e = acRecord(w, fpOf("strong-" & $i & "-" & $j), 0)
        check s.insert(e) in {isInserted, isExists}
        byWeak[hexOf(w)].incl hexOf(e)
      let ec = acEdgeComplete(w, 0)
      check s.insert(ec) in {isInserted, isExists}
      byWeak[hexOf(w)].incl hexOf(ec)
    check s.shardCount() > 3                  # the runs really are split up

    var maxVisited = 0
    for w in weaks:
      var got = initHashSet[string]()
      var visited = 0
      for v in s.withPrimaryKey(w):
        inc visited
        if acIsWellFormed(v.bytes) and acWeak(v.bytes) == w:
          got.incl hexOf(v.bytes)
      maxVisited = max(maxVisited, visited)
      check got == byWeak[hexOf(w)]           # complete, in every shard
    # Bounded by the CLUSTER, not by the table. Sum the chain's slot capacity and
    # assert the longest walk is a small fraction of it — the property that makes
    # the chain-free multimap viable at all.
    var totalSlots = 0
    var capK = 64
    for k in 0 ..< s.shardCount():
      totalSlots += capK
      capK *= GrowthFactor
    check maxVisited * 20 < totalSlots
    check maxVisited < 200
    s.detach()

  test "B4 a run split ACROSS shards enumerates over the union":
    # One edge whose elements straddle a growth boundary: some land in shard0,
    # the rest in later shards. The walk over the chain must return all of them.
    let dir = freshDir("split")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 16, shard0ArenaCap = 1024)
    check s.available
    let weak = fpOf("straddling-edge")
    var expected = initHashSet[string]()
    for j in 0 ..< 60:
      let e = acRecord(weak, fpOf("st-" & $j), 0)
      check s.insert(e) in {isInserted, isExists}
      expected.incl hexOf(e)
    check s.shardCount() > 1
    var shardsSeen = initHashSet[int]()
    var got = initHashSet[string]()
    for v in s.withPrimaryKey(weak):
      if acIsWellFormed(v.bytes) and acWeak(v.bytes) == weak:
        got.incl hexOf(v.bytes)
        shardsSeen.incl v.shardIndex
    check got == expected
    check shardsSeen.len > 1                  # genuinely split across shards
    s.detach()

  test "B5 a walk never terminates early at a slot claimed after it started":
    # A run that is EXTENDED between two walks must be fully visible to the
    # second walk; nothing about the first walk can truncate it. (The structural
    # reason: a claim only ever turns an empty slot non-empty, so a run only ever
    # grows to the right; no slot is ever emptied, so no run is ever punctured.)
    let dir = freshDir("extend")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 256, shard0ArenaCap = 1 shl 18)
    check s.available
    let weak = fpOf("growing-edge")
    var expected = initHashSet[string]()
    for round in 0 ..< 10:
      let e = acRecord(weak, fpOf("g-" & $round), 0)
      check s.insert(e) == isInserted
      expected.incl hexOf(e)
      var got = initHashSet[string]()
      for v in s.withPrimaryKey(weak):
        if acWeak(v.bytes) == weak: got.incl hexOf(v.bytes)
      check got == expected                   # complete after every extension
    s.detach()

# ---------------------------------------------------------------------------
# C. idempotence and convergence
# ---------------------------------------------------------------------------

suite "C. idempotence and convergence (the join-semilattice property)":

  test "C1 re-inserting identical bytes writes NOTHING":
    let dir = freshDir("idem")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 512, shard0ArenaCap = 1 shl 20)
    check s.available
    let weak = fpOf("edge-idem")
    var elems: seq[seq[byte]]
    for j in 0 ..< 20: elems.add acRecord(weak, fpOf("s" & $j), 0)
    for e in elems: check s.insert(e) == isInserted
    let claimed = s.claimedSlots()
    for rep in 0 ..< 5:
      for e in elems: check s.insert(e) == isExists
    check s.claimedSlots() == claimed         # not one extra slot
    check s.snapshot().len == elems.len
    s.detach()

  test "C2 union is order-independent across writers and shards":
    # The same element multiset inserted in three different orders (and with
    # different shard geometries, so the elements land in different shards) must
    # converge on the same set AND on the same per-edge enumeration.
    var population: seq[seq[byte]]
    for i in 0 ..< 40:
      let w = fpOf("conv-edge-" & $i)
      for j in 0 .. (i mod 3):
        population.add acRecord(w, fpOf("conv-s-" & $i & "-" & $j), 0)
      population.add acEdgeComplete(w, 0)

    var results: seq[HashSet[string]]
    for variant in 0 ..< 3:
      let dir = freshDir("conv" & $variant)
      defer: removeDir(dir)
      var order = population
      var rng = initRand(1234 + variant)
      rng.shuffle(order)
      var s = createSetT(dir, "repro", "index", AcIndexKey,
        shard0Cap = (if variant == 0: 1024 else: 16),
        shard0ArenaCap = (if variant == 0: 1 shl 20 else: 512))
      check s.available
      for e in order: check s.insert(e) in {isInserted, isExists}
      var got = initHashSet[string]()
      for e in s.items: got.incl hexOf(e)
      results.add got
      # and the per-edge walk agrees with the global union
      for i in 0 ..< 40:
        let w = fpOf("conv-edge-" & $i)
        var run = initHashSet[string]()
        for v in s.withPrimaryKey(w):
          if acIsWellFormed(v.bytes) and acWeak(v.bytes) == w:
            run.incl hexOf(v.bytes)
        var expect = initHashSet[string]()
        for e in population:
          if acWeak(e) == w: expect.incl hexOf(e)
        check run == expect
      s.detach()
    check results[0] == results[1]
    check results[1] == results[2]

# ---------------------------------------------------------------------------
# D. tombstone semantics
# ---------------------------------------------------------------------------

proc liveIdSet(s: var ShmGSetT[AcIndexKey]; weak: Fp32): HashSet[string] =
  result = initHashSet[string]()
  let v = s.acScanEdge(weak)
  for id in v.liveIdentities: result.incl id

suite "D. tombstone semantics (eviction is an ordinary insert)":

  test "D1 live -> evicted -> resurrected, all by insert only":
    let dir = freshDir("tomb")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 256, shard0ArenaCap = 1 shl 18)
    check s.available
    let weak = fpOf("edge-tomb")
    let strong = fpOf("strong-tomb")
    let id = acIdentity(acRecord(weak, strong, 0))

    check s.acInsert(akRecord, weak, strong) == isInserted
    check id in s.liveIdSet(weak)
    check s.acInsert(akRecord, weak, strong) == isExists  # live => no write

    check s.acEvict(akRecord, weak, strong) == isInserted
    check id notin s.liveIdSet(weak)                      # retired
    # The record element itself was NOT removed — nothing ever is.
    var stillThere = false
    for v in s.withPrimaryKey(weak):
      if acWeak(v.bytes) == weak and not acIsTombstone(v.bytes) and
         acIdentity(v.bytes) == id: stillThere = true
    check stillThere

    check s.acInsert(akRecord, weak, strong) == isInserted # resurrection
    check id in s.liveIdSet(weak)
    check s.acEvict(akRecord, weak, strong) == isInserted  # and re-evict
    check id notin s.liveIdSet(weak)
    s.detach()

  test "D2 an OLDER tombstone does not retire a NEWER record":
    let dir = freshDir("tombold")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 256, shard0ArenaCap = 1 shl 18)
    check s.available
    let weak = fpOf("edge-old")
    let strong = fpOf("strong-old")
    let id = acIdentity(acRecord(weak, strong, 0))
    # Hand-stamped generations, inserted in the "wrong" order on purpose.
    check s.insert(acRecord(weak, strong, 7)) == isInserted
    check s.insert(acRecord(weak, strong, 3, tombstone = true)) == isInserted
    check id in s.liveIdSet(weak)             # tombstone gen 3 < record gen 7
    check s.insert(acRecord(weak, strong, 9, tombstone = true)) == isInserted
    check id notin s.liveIdSet(weak)          # tombstone gen 9 > record gen 7
    check s.insert(acRecord(weak, strong, 11)) == isInserted
    check id in s.liveIdSet(weak)             # record gen 11 > tombstone gen 9
    s.detach()

  test "D3 a tombstone must be STRICTLY newer; a tie leaves the key live":
    let dir = freshDir("tombtie")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 256, shard0ArenaCap = 1 shl 18)
    check s.available
    let weak = fpOf("edge-tie")
    let strong = fpOf("strong-tie")
    let id = acIdentity(acRecord(weak, strong, 0))
    check s.insert(acRecord(weak, strong, 5)) == isInserted
    check s.insert(acRecord(weak, strong, 5, tombstone = true)) == isInserted
    check id in s.liveIdSet(weak)             # a tie is NOT "newer": still live

    # This is exactly why `acEvict` allocates a FRESH generation from the global
    # counter instead of reusing the current one — and why the counter must
    # dominate every generation ever stamped (`acInsert`/`acEvict` maintain that;
    # the hand-stamped inserts above deliberately violate it to isolate the tie
    # rule, so restore it the way a real writer would before evicting).
    check s.controlWordBumpTo(AcGenWord, 5) == 5
    check s.acEvict(akRecord, weak, strong) == isInserted
    check id notin s.liveIdSet(weak)
    # A fresh generation was allocated, strictly above every stamped one.
    check s.controlWord(AcGenWord) > 5
    s.detach()

  test "D4 a tombstone never hides the WRONG key — not even in its own run":
    # Three keys sharing one weak fingerprint (so ONE probe run), an
    # edge-complete element for the same edge, and a foreign edge deliberately
    # colliding into the same home slot. Evicting one key must retire exactly
    # that key.
    let dir = freshDir("tombscope")
    defer: removeDir(dir)
    const cap = 512
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = cap, shard0ArenaCap = 1 shl 18)
    check s.available
    let weaks = collidingWeaks(cap, 2)
    let weak = weaks[0]
    let foreignWeak = weaks[1]
    var strongs: seq[Fp32]
    for j in 0 ..< 3: strongs.add fpOf("scope-s-" & $j)
    for st in strongs: check s.acInsert(akRecord, weak, st) == isInserted
    var zero: Fp32
    check s.acInsert(akEdgeComplete, weak, zero) == isInserted
    let foreignStrong = fpOf("scope-foreign")
    check s.acInsert(akRecord, foreignWeak, foreignStrong) == isInserted

    let ecId = acIdentity(acEdgeComplete(weak, 0))
    var ids: seq[string]
    for st in strongs: ids.add acIdentity(acRecord(weak, st, 0))
    let foreignId = acIdentity(acRecord(foreignWeak, foreignStrong, 0))

    check s.acEvict(akRecord, weak, strongs[1]) == isInserted
    let live = s.liveIdSet(weak)
    check ids[0] in live
    check ids[1] notin live                   # exactly the evicted one
    check ids[2] in live
    check ecId in live                        # the completeness claim survives
    check foreignId in s.liveIdSet(foreignWeak)   # the foreign edge is untouched
    check s.acEdgeIsComplete(weak)

    # Withdrawing the completeness claim retires ONLY it.
    check s.acEvict(akEdgeComplete, weak, zero) == isInserted
    let live2 = s.liveIdSet(weak)
    check ecId notin live2
    check ids[0] in live2
    check ids[2] in live2
    check (not s.acEdgeIsComplete(weak))
    s.detach()

  test "D5 liveness is independent of the ORDER records and tombstones arrive":
    # Every permutation of {record@2, tombstone@5, record@9, tombstone@4} must
    # decide the same way: the newest record (9) beats every tombstone (5, 4).
    let elems = @[(2'u64, false), (5'u64, true), (9'u64, false), (4'u64, true)]
    var order = @[0, 1, 2, 3]
    let weak = fpOf("edge-perm")
    let strong = fpOf("strong-perm")
    let id = acIdentity(acRecord(weak, strong, 0))
    var perms = 0
    order.sort()
    while true:
      let dir = freshDir("perm" & $perms)
      var s = createSetT(dir, "repro", "index", AcIndexKey,
        shard0Cap = 16, shard0ArenaCap = 512)   # tiny: spreads across shards
      check s.available
      for k in order:
        let (g, t) = elems[k]
        check s.insert(acRecord(weak, strong, g, tombstone = t)) in
          {isInserted, isExists}
      check id in s.liveIdSet(weak)
      s.detach()
      removeDir(dir)
      inc perms
      if not order.nextPermutation(): break
    check perms == 24

  test "D6 the decision holds ACROSS shards (a global generation order)":
    # Record in an early shard, tombstone in a later one, resurrection in a later
    # one still: the u64 generation is a total order over the whole chain, so the
    # shard an element landed in is irrelevant.
    let dir = freshDir("tombshard")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "index", AcIndexKey,
      shard0Cap = 16, shard0ArenaCap = 512)
    check s.available
    let weak = fpOf("edge-xshard")
    let strong = fpOf("strong-xshard")
    let id = acIdentity(acRecord(weak, strong, 0))
    check s.acInsert(akRecord, weak, strong) == isInserted
    let shardOfRecord = s.shardCount() - 1
    # Fill with unrelated edges until the chain grows past that shard.
    var filler = 0
    while s.shardCount() <= shardOfRecord + 1:
      check s.insert(acRecord(fpOf("filler-" & $filler),
        fpOf("fs-" & $filler), 0)) in {isInserted, isExists}
      inc filler
      doAssert filler < 100_000
    check s.acEvict(akRecord, weak, strong) == isInserted
    check id notin s.liveIdSet(weak)
    while s.shardCount() <= shardOfRecord + 2:
      check s.insert(acRecord(fpOf("filler-" & $filler),
        fpOf("fs-" & $filler), 0)) in {isInserted, isExists}
      inc filler
      doAssert filler < 200_000
    check s.acInsert(akRecord, weak, strong) == isInserted
    check id in s.liveIdSet(weak)
    # and the record, tombstone and resurrection really did land in >1 shard
    var shards = initHashSet[int]()
    for v in s.withPrimaryKey(weak):
      if acWeak(v.bytes) == weak: shards.incl v.shardIndex
    check shards.len > 1
    s.detach()

# ---------------------------------------------------------------------------
# E. no heap allocation on the insert path
# ---------------------------------------------------------------------------

proc insertBatchNoAlloc[K](s: var ShmGSetT[K]; buf: var seq[byte];
    lo, hi: int): int =
  ## Mutate ONE preallocated buffer in place and insert it repeatedly, so the
  ## only allocations the measured window can attribute are the insert path's
  ## own. See `E1` for why residency is the wrong instrument here.
  for i in lo ..< hi:
    buf[0] = byte(i and 0xFF)
    buf[1] = byte((i shr 8) and 0xFF)
    buf[2] = byte((i shr 16) and 0xFF)
    if s.insert(buf) == isInserted: inc result

suite "E. the insert path allocates nothing on the heap":

  test "E1 IdentityKey and AcIndexKey inserts perform ZERO allocations":
    # The instrument is `getAllocStats`, which counts alloc/dealloc EVENTS.
    #
    # Residency (`getOccupiedMem`) cannot express this property: a per-insert
    # buffer that is allocated and freed inside the loop returns its block to
    # the allocator, so the before/after delta is zero and the measurement is
    # blind to exactly the allocation this suite exists to forbid. Verified by
    # mutation — injecting a `newSeq` into `insert` left a residency-based
    # check reporting [OK], and fails this one.
    #
    # `getAllocStats` is only instrumented under `-d:nimAllocStats`; without it
    # the runtime returns `default(AllocStats)` unconditionally, which would
    # make this test silently vacuous. `allocationCountingIsLive` below is the
    # guard: it performs an allocation that must be observed, and fails the
    # test — rather than passing emptily — if the counters are inert.
    let zero = getAllocStats() - getAllocStats()
    var guardSink = 0
    let gBefore = getAllocStats()
    block:
      var deliberate = newSeq[byte](64)
      deliberate[0] = 7'u8
      guardSink += int(deliberate[0])
    let allocationCountingIsLive = (getAllocStats() - gBefore) != zero
    check guardSink == 7
    require allocationCountingIsLive  # compile with -d:nimAllocStats

    let dir = freshDir("noalloc")
    defer: removeDir(dir)
    # Geometry large enough that the measured window triggers no growth (growth
    # legitimately allocates: it maps a new file and extends the shard seq).
    var a = createSetT(dir, "io-mon", "ident", IdentityKey,
      shard0Cap = 1 shl 14, shard0ArenaCap = 1 shl 22)
    var b = createSetT(dir, "repro", "acidx", AcIndexKey,
      shard0Cap = 1 shl 14, shard0ArenaCap = 1 shl 22)
    check a.available and b.available
    var bufA = newSeq[byte](48)
    var bufB = newSeq[byte](AcRecordSize)
    bufB[0] = AcMagic[0]; bufB[1] = AcMagic[1]
    bufB[2] = AcMagic[2]; bufB[3] = AcMagic[3]
    # Warm up: map shards, let the runtime settle.
    discard insertBatchNoAlloc(a, bufA, 0, 200)
    discard insertBatchNoAlloc(b, bufB, 0, 200)
    let residentBefore = getOccupiedMem()
    let beforeA = getAllocStats()
    let nA = insertBatchNoAlloc(a, bufA, 200, 1200)
    let afterA = getAllocStats()
    let nB = insertBatchNoAlloc(b, bufB, 200, 1200)
    let afterB = getAllocStats()
    check nA > 0
    check nB > 0
    check a.shardCount() == 1                 # no growth in the window
    check b.shardCount() == 1
    check (afterA - beforeA) == zero          # 1000 identity inserts: 0 allocs
    check (afterB - afterA) == zero           # 1000 keyed inserts:    0 allocs
    # Residency is a supplementary check, not the property: it cannot see a
    # balanced alloc/dealloc pair, but it does catch an allocation that is
    # RETAINED across the window, which the event counters alone would report
    # as merely one more alloc.
    check getOccupiedMem() == residentBefore
    a.detach(); b.detach()

# ---------------------------------------------------------------------------
# F. policy isolation
# ---------------------------------------------------------------------------

suite "F. a chain cannot be read under the wrong key discipline":

  test "F1 attach refuses a chain written under another policy":
    let dir = freshDir("policy")
    defer: removeDir(dir)
    var ident = createSetT(dir, "io-mon", "one", IdentityKey,
      shard0Cap = 64, shard0ArenaCap = 4096)
    var keyed = createSetT(dir, "repro", "two", AcIndexKey,
      shard0Cap = 64, shard0ArenaCap = 4096)
    check ident.available and keyed.available
    # Right discipline: attaches.
    var okA = attachSetT(ident.path0, IdentityKey)
    var okB = attachSetT(keyed.path0, AcIndexKey)
    check okA.available and okB.available
    # Wrong discipline: refused (format-version guard), never misread.
    var badA = attachSetT(ident.path0, AcIndexKey)
    var badB = attachSetT(keyed.path0, IdentityKey)
    check (not badA.available)
    check (not badB.available)
    check (not attachSet(keyed.path0).available)   # io-mon's plain entry point
    okA.detach(); okB.detach(); ident.detach(); keyed.detach()

  test "F2 the extra control block does not disturb the identity layout":
    # AcIndexKey reserves two control words, which pushes its slot array past the
    # fixed header; IdentityKey reserves none and keeps slots at offset 128.
    check slotsOffFor(0) == ShardHeaderSize
    check slotsOffFor(extraControlWords(IdentityKey)) == ShardHeaderSize
    check slotsOffFor(extraControlWords(AcIndexKey)) > ShardHeaderSize
    check shardFileSize(64, 2048) == shardFileSize(64, 2048, 0)

  test "F3 the generation counter is global, monotonic and lives in shard0":
    let dir = freshDir("gen")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "gen", AcIndexKey,
      shard0Cap = 16, shard0ArenaCap = 512)
    check s.available
    check s.controlWord(AcGenWord) == 0
    var last = 0'u64
    for i in 0 ..< 50:
      let g = s.controlWordFetchAdd(AcGenWord, 1) + 1
      check g > last
      last = g
    check s.controlWord(AcGenWord) == last
    check s.controlWordBumpTo(AcGenWord, last - 10) == last   # never lowers
    check s.controlWord(AcGenWord) == last
    check s.controlWordBumpTo(AcGenWord, last + 5) == last + 5
    # A second attached view of the same chain sees the same counter.
    var v = attachSetT(s.path0, AcIndexKey)
    check v.available
    check v.controlWord(AcGenWord) == last + 5
    # ... and it stays in shard0 even after the chain grows.
    var filler = 0
    while s.shardCount() < 3:
      discard s.insert(acRecord(fpOf("gf-" & $filler), fpOf("gs-" & $filler), 0))
      inc filler
      doAssert filler < 100_000
    check s.controlWord(AcGenWord) == last + 5
    v.detach(); s.detach()

# ---------------------------------------------------------------------------
# G. flatten and retire
# ---------------------------------------------------------------------------

suite "G. flatten-then-retire never makes an element unobservable":

  test "G1 copy forward, drain, unlink — the edge enumeration is stable":
    let dir = freshDir("flatten")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "flat", AcIndexKey,
      shard0Cap = 16, shard0ArenaCap = 1024)
    check s.available
    var weaks: seq[Fp32]
    for i in 0 ..< 40:
      let w = fpOf("flat-edge-" & $i)
      weaks.add w
      for j in 0 .. (i mod 2):
        check s.acInsert(akRecord, w, fpOf("flat-s-" & $i & "-" & $j)) ==
          isInserted
    # Evict a few so the older shards genuinely carry superseded elements.
    for i in 0 ..< 10:
      check s.acEvict(akRecord, weaks[i], fpOf("flat-s-" & $i & "-0")) ==
        isInserted
    check s.shardCount() >= 3

    proc liveCensus(s: var ShmGSetT[AcIndexKey];
        weaks: seq[Fp32]): Table[string, HashSet[string]] =
      result = initTable[string, HashSet[string]]()
      for w in weaks: result[hexOf(w)] = s.liveIdSet(w)

    let before = liveCensus(s, weaks)

    # Flatten shard 1 forward: copy each of its elements into the newest shard,
    # THEN mark it drained, THEN unlink it. (The ordering is the whole safety
    # argument; a reader visits shards oldest-first, so it sees each element in
    # the source, the destination, or both — never in neither.)
    var copied: seq[seq[byte]]
    for v in s.shardElements(1): copied.add v.toBytesSeq()
    check copied.len > 0
    for e in copied: check s.insert(e) in {isInserted, isExists}
    check liveCensus(s, weaks) == before      # copy-forward changed nothing

    check s.markShardDrained(1)
    check s.shardIsDrained(1)
    check liveCensus(s, weaks) == before      # draining changed nothing

    let path0 = s.path0
    check s.retireShard(1)
    check (not fileExists(path0[0 ..< path0.len - 1] & "1"))
    check liveCensus(s, weaks) == before      # unlinking changed nothing
    s.detach()

    # And a FRESH attach — a process that never mapped the retired shard, so it
    # must reach the copied-forward elements and must not stall on the hole in
    # the chain — reaches the same verdict.
    var fresh = attachSetT(path0, AcIndexKey)
    check fresh.available
    check liveCensus(fresh, weaks) == before
    fresh.detach()

  test "G2 shard0 is never drained or retired (it holds the control block)":
    let dir = freshDir("flatten0")
    defer: removeDir(dir)
    var s = createSetT(dir, "repro", "flat0", AcIndexKey,
      shard0Cap = 16, shard0ArenaCap = 512)
    check s.available
    for i in 0 ..< 20:
      discard s.insert(acRecord(fpOf("z-" & $i), fpOf("zs-" & $i), 0))
    check (not s.markShardDrained(0))
    check (not s.retireShard(0))
    check fileExists(s.path0)
    check (not s.retireShard(1))              # not drained yet => refused
    s.detach()

  test "G3 a walk IN FLIGHT sees a shard the flatten created after it started":
    # The regression this guards: a chain-wide walk that fixes its shard bound
    # when it starts. Flattening migrates elements INTO the newest shard, which
    # is precisely what makes the chain grow — so a walk that snapshotted its
    # bound will skip the drained source AND never reach the destination,
    # losing an element that was observable when the walk began and is still in
    # the set.
    #
    # The TLA+ reader in `shm_gset_keyed.tla` visits every shard up to the
    # MaxShards constant, so `ReaderCompleteUnderFlatten` is proved for a reader
    # with no snapshot. This test is what ties the implementation to that model.
    let dir = freshDir("inflight")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 64,
      shard0ArenaCap = 1 shl 16)
    check s.available
    var i = 0
    while s.shardCount() < 2:
      check s.insert(bytesOf("pre-" & $i)) in {isInserted, isExists}
      inc i
    var victims: seq[seq[byte]]
    for v in 0 ..< 40:                        # these land in shard 1
      let e = bytesOf("victim-" & $v)
      check s.insert(e) == isInserted
      victims.add e
    while s.shardCount() < 3:                 # shard 1 becomes a MIDDLE shard
      check s.insert(bytesOf("mid-" & $i)) in {isInserted, isExists}
      inc i
    let nSnapshot = s.shardCount()

    # A victim whose probe run yields from shard 0 before reaching shard 1, so
    # the flatten can fire while the walk is still upstream of the victim.
    var chosen: seq[byte]
    for e in victims:
      var firstShard = -1
      var eShard = -1
      for view in s.withPrimaryKeyHash(s.elementKeyHash(e)):
        if firstShard < 0: firstShard = view.shardIndex
        if view.toBytesSeq() == e: eShard = view.shardIndex
      if firstShard == 0 and eShard == 1:
        chosen = e; break
    check chosen.len > 0                      # the setup itself must hold

    var sawVictim = false
    var didFlatten = false
    var shardsVisited: seq[int]
    for view in s.withPrimaryKeyHash(s.elementKeyHash(chosen)):
      shardsVisited.add view.shardIndex
      if view.toBytesSeq() == chosen: sawVictim = true
      if not didFlatten and view.shardIndex == 0:
        didFlatten = true
        while s.shardCount() == nSnapshot:    # grow PAST the walk's start
          check s.insert(bytesOf("filler-" & $i)) in {isInserted, isExists}
          inc i
        var copied: seq[seq[byte]]
        for w in s.shardElements(1): copied.add w.toBytesSeq()
        for e in copied: check s.insert(e) in {isInserted, isExists}
        check s.markShardDrained(1)
        check s.retireShard(1)
    check didFlatten                          # the race actually fired
    check s.shardCount() > nSnapshot          # the chain actually grew
    # The walk must have entered a shard that did not exist when it began —
    # otherwise the scenario never exercised the bound and the test is vacuous.
    var enteredNewShard = false
    for k in shardsVisited:
      if k >= nSnapshot: enteredNewShard = true
    check enteredNewShard
    check s.contains(chosen)                  # still in the set...
    check sawVictim                           # ...and the in-flight walk saw it
    s.detach()

  test "G4 retire REFUSES a shard it merely failed to map (unlink is final)":
    # `shardIsDrained` answers "may a reader skip this?", and treating an
    # unopenable shard as skippable is correct there. Unlinking needs the
    # opposite default: `openShard` returns false for a missing file, a
    # truncated file, an `open` failure and a version mismatch alike, so
    # deriving "drained" from it would let a shard that was never copied
    # forward be deleted. Only a header actually read may authorise the unlink.
    let dir = freshDir("retireguard")
    defer: removeDir(dir)
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 64,
      shard0ArenaCap = 1 shl 16)
    check s.available
    var i = 0
    while s.shardCount() < 2:
      check s.insert(bytesOf("g4-" & $i)) in {isInserted, isExists}
      inc i
    let victimPath = s.path0[0 ..< s.path0.len - ".shard0".len] & ".shard1"
    check fileExists(victimPath)
    let liveBytes = readFile(victimPath).len
    check liveBytes > 0

    # A live, NOT-drained shard that cannot be mapped: truncate it below the
    # header, which is one of the several distinct reasons `openShard` fails.
    var fresh = createSet(dir, "io-mon", "edge", shard0Cap = 64,
      shard0ArenaCap = 1 shl 16)                # a peer that has not mapped it
    check fresh.available
    writeFile(victimPath, "")
    check (not fresh.retireShard(1))            # refuses: not known to be drained
    check fileExists(victimPath)                # and did NOT unlink it
    fresh.detach()

    # Retiring a shard that is genuinely gone is a no-op that succeeds.
    removeFile(victimPath)
    var after = createSet(dir, "io-mon", "edge", shard0Cap = 64,
      shard0ArenaCap = 1 shl 16)
    check after.retireShard(1)
    after.detach()
    s.detach()
