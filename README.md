# nim-shm-gset

A shared-memory, lock-free, **grow-only set (G-Set)** for Nim — the Candidate-C
transport of the *io-mon Lossless Event Capture* campaign
(`reprobuild-specs/io-mon-Lossless-Event-Capture.md`). Sibling to
[`nim-shm-queue`](../nim-shm-queue); domain-free (the element is an opaque byte
blob — the consumer supplies the encoding).

## What it is

A **state-based (convergent) CRDT**: a bounded join-semilattice whose merge is
**set union**. Insert is idempotent, nothing is ever deleted, merge is
order-independent — which is exactly why the shard-and-merge model is correct
regardless of write order, writer, or duplication.

- **Pure membership.** The only shared-memory mutation is an idempotent
  *slot-claim* (CAS an empty slot to an element-record offset). There is **no
  per-element mutable value and no atomic value read-modify-write**, so the
  lost-update race class does not exist.
- **Dedup at the source.** Re-observing an element is one CAS that finds it
  present and returns; the structure is bounded by *distinct* elements, not
  *events*. A probe storm (the same path stat'd thousands of times) collapses,
  so backpressure never arises — no producer ever blocks, no consumer drains.
- **Lock-free open-addressed hash table**, linear-probe on collision.
- **File-backed** (one file per shard, `mmap(MAP_SHARED)`): "persists" == "the
  file exists", decoupled from mapping count, surviving producer death and
  `exec` (the cross-OS lifetime the campaign requires).
- **Position-independent**: the only things in shared memory are **offsets**
  (a slot holds the byte offset of its record within the same shard) and
  **counts** (the chain length). No absolute pointer lives in the segment, so it
  maps correctly at a different virtual base in every process.
- **Growth by sharding, not migration**: when the newest shard crosses a load
  threshold, a producer links a new, larger shard file onto the chain
  (exclusive `link`, so a double-grow never leaks a shard file); inserts
  continue there. The control block (chain count, consumer liveness,
  growth-failure counter) lives in the first shard. Publish-before-write: a
  shard is fully initialised and linked under its final name before the chain
  count is bumped, and the reader also directory-scans, so a crash never strands
  discoverable data.
- **Intern arena**: an append-only bump allocator holds the variable-length
  element bytes; the slot references its record by offset (no hot-path heap
  allocation on insert).
- **Single-threaded final merge**: the reader unions all shards into the
  authoritative distinct set (`items` / `snapshot`).
- **Reaper** (`reapStaleSegments(dir, appId)`): cross-restart GC of shard files
  whose owner is gone (boot-id + owner-pid staleness, `flock`-guarded against a
  starting run). SCOPED to one `appId`: anchors are named
  `{appId}~{chainSeq}.{boot}.{pid}.shardN`, and the reaper only considers its own
  app's anchors, so one application never reaps another's segments even when
  they share a directory (the reserved `~` keeps the appId unambiguous). The
  name carries only what SCOPING and STALENESS need — `chainSeq` is an opaque
  per-owner uniquifier, not an identity. The run IDENTITY is a **header** field
  (`reapStaleSegmentsDetailed` reports it per collected chain, `runId` reads it
  off an attached chain), so a recycled chain is re-stamped in place and can
  never carry a stale name-borne `runId`.
- **Deterministic schedule hooks** (`-d:shmGSetScheduleHooks`): test-only seams
  at every CAS/publish site so interleavings can be driven deterministically.
- **Portable no-op arm**: compiles everywhere; `shmGSetSupported == false` off
  Linux/macOS, where every op reports unavailable.

## The key discipline is a parameter

The structure separates three projections of an element that used to be the same
thing, and makes them a compile-time parameter `K` of `ShmGSetT[K]`:

| projection | hook | what it is |
|---|---|---|
| the bytes **stored** | — | the whole blob, memcpy'd into the arena |
| the bytes **hashed** | `primaryKeySpan` + `hashKey` | the PRIMARY KEY. All elements sharing one occupy a single contiguous probe run, so `withPrimaryKey` enumerates them with no stored chain and no pointer update |
| the thing **compared** | `identityFp` + `identityEq` | element IDENTITY: a 64-bit fast-reject fingerprint in the arena record plus the authoritative comparison |

`K` is a phantom type carrying nothing at runtime; the hooks are overloads on
`typedesc[K]`, resolved and inlined at instantiation — no vtable, no indirect
call, no heap, and nothing added to shared memory. A policy may additionally
enlarge the per-chain control block (`extraControlWords`, e.g. for a generation
counter that orders tombstones) and must then override `keyFormatVersion` so a
chain is never attached under a different discipline.

`ShmGSet = ShmGSetT[IdentityKey]` makes all three projections the identity, which
is io-mon's discipline: same API, same probe behaviour, and **byte-identical
shard files** (asserted against golden digests in `tests/test_shm_gset_keyed.nim`).

```nim
# a multimap keyed on a field of the element
type MyKey = object
proc primaryKeySpan*(_: typedesc[MyKey]; blob: openArray[byte]): tuple[a, b: int] =
  (20, 51)                                    # hash THIS sub-range only
proc keyFormatVersion*(_: typedesc[MyKey]): uint32 = 2
proc extraControlWords*(_: typedesc[MyKey]): int = 1   # e.g. a generation counter

var s = createSetT(dir, "app", "run", MyKey)
discard s.insert(element)                     # placed by primary key
for v in s.withPrimaryKey(keyBytes):          # the probe run IS the enumeration
  use(v.bytes)                                # zero-copy view, no allocation
```

## API sketch

```nim
import shm_gset

# CONSUMER (owner): create shard0, register liveness, get the well-known path.
var s = createSet(dir, runId)          # shard0Cap / shard0ArenaCap optional
setEnv("REPRO_MONITOR_DEP_SHM", s.path0)

# PRODUCER: attach by shard0 path; insert is idempotent + lossless.
var p = attachSet(path0)
discard p.insert(elementBytes)         # isInserted | isExists | isSaturated | isUnavailable

# CONSUMER: single-threaded union (source of truth for the depfile).
for element in s.items: ...
echo s.shardCount(), s.growthFailures()  # metrics; growthFailures>0 ⇒ mcIncomplete
```

## Reset and recycling

**Status: IMPLEMENTED (`reset`).** Motivated by hosting the monitor
in-process (`reprobuild-specs/In-Process-Monitor-Hosting.md`): a long-lived
daemon that owns the set can hand an already-grown chain to the next action
instead of creating and growing a fresh one, so grow-only becomes an
amortisation rather than a per-action cost. A per-action monitor process cannot
do this — it dies with its segment.

The library offers this directly: **one reset operation that recycles the OS
shared memory into a fresh, empty gset**, so callers never open-code it.

```nim
proc reset*(h: var SetHost; runId: string): ResetStatus
  ## Recycle this chain into a FRESH empty set, reusing the mapped shards.
  ## Consumer-only. Requires quiescence (see below).
```

The status is RETURNED, not a `void` with a documented precondition: the
operation's defining property is that it can REFUSE (`rsBusyProducers`,
`rsProducersUntracked`, `rsGenerationExhausted`, `rsNotConsumer`,
`rsInvalidRunId`, `rsUnavailable`), and a refusal the caller cannot see is a
precondition nobody enforces one call frame later. It is not `discardable`
either.

### Generation-stamped, so reset is O(1)

The naive reset — zero the slot tables and the intern arena — costs
O(*capacity*): what the chain **grew to**, not what the next action uses, so a
small action recycling a large chain pays for the whole thing.

Instead, each slot entry is generation-STAMPED: it packs
`(generation shl 32) or offset`, and a slot is empty unless its stamp equals the
chain's current generation. Reset is then a **single store, O(1) at any chain
size** — measured flat at ~2 µs whether the chain has one shard or six (1.9 vs
2.0 µs on an idle machine, 2.24 vs 2.23 µs on a loaded one: the absolute number
moves, the two do not diverge) and
asserted structurally by `reset_is_constant_time`, which shows reset writes
nothing outside shard0's fixed header.

The generation lives IN the entry rather than beside it so the claim stays a
single-word CAS; a (generation, offset) pair in two words could not be claimed
atomically, and a claim that is not atomic is a torn slot. The per-shard arena
bump pointer, occupancy counter and growth-failure counter are stamped the same
way, so each **rebases itself** on first use in a new generation and reset does
not have to walk the chain to reclaim them either. Stale bytes stay resident but
are unreachable, because no slot referencing them matches the current
generation.

Two bounds follow from the packing and are ENFORCED rather than assumed:
a shard file may not reach `MaxShardBytes` (4 GiB — growth past it is a
SIGNALLED saturation, never a truncated offset), and a chain may not be recycled
more than `MaxGeneration` (2^32-1) times. On reaching the last generation
`reset` returns `rsGenerationExhausted` and the caller creates a new chain.
Wrapping would make a slot written 4.29e9 recycles ago read as live under the
reused stamp, and the alternative — scrubbing every slot on wrap — is both
O(capacity) and NOT crash-atomic, since it destroys the old contents before the
commit point.

The generation is a field of the FIXED header, not a policy-owned
`extraControlWords` entry. The milestone assumed the latter (the doc comment on
`extraControlWords` advertises "a global generation counter"), but it is the
wrong hook here for two reasons: the extra control words are the POLICY's, and
the keyed action-cache discipline already uses word 0 for its own tombstone
generation, which the library would have had to steal; and reserving one for
every discipline would shift the slot array for all of them a second time. The
chain generation is a library-level concept that every key discipline needs, so
it belongs in the header.

This is also what makes recycling *correct* rather than merely cheap: entries
from the previous action cannot be read back, so one action's dependencies can
never be attributed to another.

### The quiescence precondition is the crux

Reset is sound only when **no producer can be mid-insert**. A producer sitting
between its arena reserve and its slot publish when the generation flips would
land bytes in the recycled set, and they would be attributed to the *next*
action — a wrong dependency set, the cardinal sin this library exists to
prevent.

The natural quiescence point is "the monitored process tree has fully exited".
**That must be checked, not assumed.** The §4.1 incident is precisely a
descendant that outlived its root and kept producing — the same class that makes
reset dangerous. So `reset` verifies no live attached producers remain and
**refuses** otherwise, rather than trusting the caller's lifecycle.

The evidence lives in the chain: shard0 carries a **producer registry**
(`MaxRegisteredProducers` pid entries). `attachSet` claims one and `detach`
releases it; `reset` refuses while any registered pid is still alive
(`attachedProducers` exposes the same predicate). A producer that dies without
detaching leaves a dead pid, which is reclaimed by whoever next scans, so a
crash does not make a chain permanently unrecyclable; pid REUSE can only make
the scan see a live pid that is not really a producer, i.e. cause a spurious
refusal, which is the conservative direction. A release only ever clears the
CALLING process's own entry, which is what makes it fork-safe: io-mon's shim
detaches the inherited handle in a fork CHILD and re-attaches under the child's
own pid, and an unconditional clear there would deregister a parent that is
still alive and producing. A producer that finds the registry
full still attaches — never fail a producer for a bookkeeping reason — but
counts itself in an overflow word, and `reset` refuses while that is nonzero,
reporting `rsProducersUntracked` rather than `rsBusyProducers`. The distinction
matters: a busy chain becomes recyclable again when those processes exit, but an
UNTRACKED producer that dies without detaching leaves a count that never falls,
so a pool must retire that chain instead of retrying it. Reporting both the same
way would let a chain quietly stop recycling forever.

Checking is not enough on its own, and this is the part the TLA+ model caught:
a producer can attach in the window BETWEEN the check and the commit, and then
insert under the new generation. So the check is bracketed by a **seal**. Reset
stores the seal and then scans the registry; an attaching producer claims its
registry entry and then reads the seal, backing out if it is set. That is a
store-buffer (Dekker) shape, and "neither side sees the other" is permitted by
release/acquire AND by x86-TSO — so those four accesses, and only those four,
are sequentially consistent. Removing the seal from the model violates the
no-cross-generation-leakage invariant; downgrading it to release/acquire in the
C11 core reproduces the leak on real x86-64 hardware.

**This is the case for the §4.5 tier, and it is worth stating plainly.** The
quiescence check passes every functional test that can be written for it: the
chain really is quiescent when it is checked, every producer really has exited,
and a test can only observe the states the implementation lets it reach. The
model found the hole because it explores the interleaving where a producer
attaches AFTER the check and BEFORE the commit — a window a few instructions
wide that no functional test would ever have hit, and whose consequence is not a
crash but a silently wrong dependency set. The seal, the one `seq_cst` pair in
the library, exists because of a TLC counterexample, not because of a red test.

### Ordering and the atomic commit point

The generation bump is the commit. Everything else must be ordered **before** it
becomes visible:

- **Re-arm the consumer-liveness token.** `markConsumerGone` used to be
  terminal; a recycled chain whose token is still "gone" makes every producer on
  the next action fast-fail with `emConsumerGone` — monitored by nobody,
  silently. Reset re-arms it and only then publishes the generation, and
  `consumerAlive` acquire-loads the GENERATION first and the token second, so
  observing the new generation implies observing the re-armed token. (The
  transport now also exposes `markConsumerGone` on its own, so an action can be
  ended without tearing the chain down.)
- **Crash mid-reset must leave the chain fully-old or fully-new**, never half.
  A single release-store of the generation gives that — including for the
  IDENTITY, which is why there are **two runId slots** selected by
  `generation and 1`. Reset stamps the slot the NEXT generation will select,
  never the one currently being read, so a crash before the commit leaves the
  old identity on the old contents. A single in-place field could not: the
  window between rewriting it and bumping the generation is a chain whose
  finished action's contents carry the next action's identity.
- **Wraparound** is refused rather than risked — see above.

### `runId` is out of the filename — **landed**

Shards used to be named `{appId}~{runId}.{boot}.{pid}.shardN`, with the reaper
splitting the run identity back out of the name. A recycled chain would then
either carry a **stale `runId`** — breaking reaper attribution and making the
on-disk shards misreport which run produced them — or have to be renamed on
every reuse, giving back part of the saving.

That is now decoupled, ahead of recycling as planned:

- anchors are `{appId}~{chainSeq}.{boot}.{pid}.shardN`; the name carries only
  what the reaper needs to SCOPE (`appId`) and to judge STALENESS (boot, owner
  pid), plus an opaque `chainSeq` that keeps one owner's chains distinct and
  carries no identity;
- `runId` is a length-prefixed field in the shard header (`ShOffRunId`,
  `RunIdMaxBytes` = 120), written by `createSetT` and authoritative in shard0 —
  the field `reset` re-stamps in place;
- `runId(chain)` reads it back (owner or attached producer), and
  `reapStaleSegmentsDetailed` reports it per collected chain
  (`runIdFromHeader` distinguishes a header read from the legacy fallback);
- the header layout revision lives in the **magic** (`ShmGSetMagic`, revision 2)
  rather than in each policy's `keyFormatVersion`, because the layout moved for
  every key discipline at once;
- a **legacy** chain (`ShmGSetMagicV1`, runId in the name) keeps the same name
  SHAPE, so it is still scoped, judged and collected by the ordinary staleness
  rule. It can no longer be attached, so being reaped once stale is the only
  outcome that does not leak it.

### Version skew is diagnosable

A header layout revision has now moved twice, and the first time it broke
SILENTLY: a producer built against the other revision simply reported
"unavailable", the edge graded `mcIncomplete`, and the dependency set came back
EMPTY with no error anywhere. Conservative — never a false cache hit — but
invisible. Three surfaces now make it legible, without changing that
conservative behaviour:

- `attachFailure` on `ShmGSetT` / `SetProducer` names WHY an attach failed, and
  `afLayoutSkew` (a genuine shm_gset shard of another header layout revision) is
  a different answer from `afNotAShard`, `afWrongBoot`, `afKeyDisciplineSkew`,
  `afMissing`, `afTruncated`, `afRecycling`. It is a QUERY and not a new
  `EmitStatus` value on purpose: consumers `case` over `EmitStatus`
  exhaustively, so a new value there would break their build rather than inform
  it.
- `shardLayoutRevision(path)` answers "which revision wrote this file?" for
  anyone, from the path alone, reading only the magic at offset 0 — whose
  position and frozen high bytes (`ShmGSetMagicBase`) are the one thing common
  to every revision.
- `producerAttaches` is the HOST-side half, and the only one that can see the
  direction that actually bit: a producer built against an OLDER layout cannot
  report into a file whose shape it does not know, so what is observable is what
  it never did. *elements == 0 AND producerAttaches == 0*, for an action that
  spawned processes, is the fingerprint of a skewed (or un-injected) producer;
  *elements == 0 AND producerAttaches > 0* means the producers really did attach
  and really did observe nothing. It is generation-stamped, so a recycled chain
  starts the count clean.

Honest limit: a build that predates a diagnostic cannot emit it, so the
`attachFailure`/`shardLayoutRevision` pair is effective from revision 3 forward
and in both directions between any two revisions that have it.

### Verification obligations

Reset is a lock-free, multi-process, weak-memory, crash-exposed operation, so it
enters the **same §4.5 regime as `insert`** — functional tests alone are
insufficient, and the model-checked core must be the shipped compilation unit.
Additions, one per hazard above (see `verification/README.md` for what RAN and
what could not):

- **TLA+** — two new safety invariants: *no element inserted before reset N is
  ever visible after reset N* (no cross-generation leakage), and *no element
  inserted after reset N is lost*. Plus: the liveness token is never observable
  as gone under the current generation.
- **GenMC / CDSChecker** — generation bump racing concurrent inserts on a tiny
  forced-collision table; exhaustive over C11 reorderings.
- **Litmus (`herd7`)** — the liveness-rearm → generation-publish release/acquire
  pair, per architecture model, alongside the existing four.
- **Quiescence refusal** — assert `reset` actually REFUSES with a live attached
  producer, including a detached/daemonized descendant that outlived its root.
  A precondition nobody enforces is a comment.
- **Kill injection mid-reset**, at every publish point: the chain reads as
  fully-old or fully-new, never half, and no shard file leaks.
- **Recycle soak** — N successive recycles with disjoint input sets; the oracle
  is that each generation's union equals exactly its intended set. This is the
  end-to-end proof that recycling cannot cross-attribute.
- **ARM64 as well as x86**, per §4.5.

The artifacts are all in place: `tests/test_shm_gset_reset.nim` (16 cases, real
forked producers, a `setsid`-detached grandchild, real `SIGKILL` at every publish
point), `tests/test_shm_gset_version_skew.nim` + `tests/helpers/v2_producer.nim`
(a separate binary speaking the rev-2 contract, because a version skew is a
disagreement between two BUILDS), `verification/tla/shm_gset_reset.tla`,
`verification/core/shm_gset_reset_core.c` (+ its `-DRELAXED_SEAL` control) and
`verification/litmus/reset-*.litmus`.

Both of the previously-open items have moved, one fully and one partly:

- **GenMC / CDSChecker / Nidhugg / herd7 are still absent from nixpkgs — so this
  repo packages them.** `flake.nix` + `nix/*.nix` build all four against a
  pinned nixpkgs, and the committed `flake.lock` is what makes the results
  reproducible instead of dependent on the machine's flake registry. The litmus
  and stateless-model-checking artifacts are now **RUN**, and one of them
  (GenMC on the RELAXED_SEAL reset core) produces the `m6` counterexample the
  TLA+ model could not even express. Full results in `verification/README.md`.
- **The ARM64 arm is PARTLY met.** The memory-ordering half is done formally:
  `verification/litmus/arch/*.AArch64.litmus` proves every shipped publish pair
  and the seal handshake Forbidden under `aarch64.cat`, and proves their
  downgrades ALLOWED there while x86-TSO forbids them — the "passes on x86,
  faults on Apple silicon" asymmetry, demonstrated rather than asserted. What
  remains open needs real silicon: the §4.5(f) multi-hour ARM64 soak, an aarch64
  Nim toolchain for the library itself (only the C cores cross-build today), and
  a real ARM64 kernel. `just verify-aarch64` remains a **functional** qemu-user
  check, and its `-DRELAXED_SEAL` control reporting ZERO is still exactly how
  you can tell qemu is not modelling the store buffer.

## Test & benchmark

```bash
just test     # functional + multi-process concurrency (or: nimble test, once committed)
just verify   # the whole §4.5 formal / weak-memory tier, all tools from flake.nix
just bench    # M1 transport head-to-head vs nim-shm-queue (needs ../nim-shm-queue)
```

`just verify` fans out to `verify-tla`, `verify-core`, `verify-litmus`,
`verify-models`, `verify-cdschecker` and `verify-aarch64`; every tool comes from
this repo's pinned flake rather than `nix shell nixpkgs#…`.

## Status

M1 skeleton (this campaign): file-backed, position-independent, sharded growth,
intern arena, single-threaded merge, reaper, schedule hooks. The full concurrency
verification plan (TLA+/GenMC/litmus, ARM64, kill-injection soak) is M2.

Apache-2.0.
