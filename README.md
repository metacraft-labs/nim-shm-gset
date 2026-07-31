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
