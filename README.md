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
  `{appId}~{runId}.{boot}.{pid}.shardN`, and the reaper only considers its own
  app's anchors, so one application never reaps another's segments even when
  they share a directory (the reserved `~` keeps the appId unambiguous).
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

**Status: designed, not implemented.** Motivated by hosting the monitor
in-process (`reprobuild-specs/In-Process-Monitor-Hosting.md`): a long-lived
daemon that owns the set can hand an already-grown chain to the next action
instead of creating and growing a fresh one, so grow-only becomes an
amortisation rather than a per-action cost. A per-action monitor process cannot
do this — it dies with its segment.

The library should offer this directly: **one reset operation that recycles the
OS shared memory into a fresh, empty gset**, so callers never open-code it.

```nim
proc reset*(h: var SetHost; runId: string)
  ## Recycle this chain into a FRESH empty set, reusing the mapped shards.
  ## Consumer-only. Requires quiescence (see below).
```

### Generation-stamped, so reset is O(1)

The naive reset — zero the slot tables and the intern arena — costs
O(*capacity*): what the chain **grew to**, not what the next action uses, so a
small action recycling a large chain pays for the whole thing.

Instead, stamp each slot with a generation and treat a slot as empty when
`slot.gen != header.gen`. Reset is then a **single increment, O(1) at any chain
size**. `extraControlWords` already exists for exactly this — it is documented
as being for "a global generation counter". The arena bump pointer resets to 0;
stale bytes stay resident but are unreachable, because no slot referencing them
matches the current generation.

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
reset dangerous. So `reset` MUST verify no live attached producers remain and
**refuse** otherwise, rather than trusting the caller's lifecycle.

### Ordering and the atomic commit point

The generation bump is the commit. Everything else must be ordered **before** it
becomes visible:

- **Re-arm the consumer-liveness token.** `finish` calls `markConsumerGone`,
  which is terminal; a recycled chain whose token is still "gone" makes every
  producer on the next action fast-fail with `emConsumerGone` — monitored by
  nobody, silently. Re-arm first, publish the generation second, or a producer
  attaching to the new generation can observe a dead consumer.
- **Crash mid-reset must leave the chain fully-old or fully-new**, never half.
  A single release-store of the generation gives that.
- **Wraparound.** A 64-bit counter never wraps in practice; if a narrower word
  is used, wraparound must be handled rather than assumed away.

### `runId` should move out of the filename

Shards are named `{appId}~{runId}.{boot}.{pid}.shardN` and the reaper parses
`runId` back out of the name. A recycled chain therefore either carries a
**stale `runId`** — breaking reaper attribution and making the on-disk shards
misreport which run produced them — or the files are renamed on every reuse,
which gives back part of the saving. Decoupling the reaper's identity from the
filename (header-only `runId`) is the cleaner fix and should be settled **before**
recycling is built.

### Verification obligations

Reset is a lock-free, multi-process, weak-memory, crash-exposed operation, so it
enters the **same §4.5 regime as `insert`** — functional tests alone are
insufficient, and the model-checked core must be the shipped compilation unit.
Additions, one per hazard above:

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

## Test & benchmark

```bash
just test     # functional + multi-process concurrency (or: nimble test, once committed)
just bench    # M1 transport head-to-head vs nim-shm-queue (needs ../nim-shm-queue)
```

## Status

M1 skeleton (this campaign): file-backed, position-independent, sharded growth,
intern arena, single-threaded merge, reaper, schedule hooks. The full concurrency
verification plan (TLA+/GenMC/litmus, ARM64, kill-injection soak) is M2.

Apache-2.0.
