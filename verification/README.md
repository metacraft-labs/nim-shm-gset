# nim-shm-gset — formal / weak-memory verification tier (design spec §4.5)

This directory is the **formal and weak-memory** verification tier for the
lock-free, multi-process, file-backed G-Set in `../src/shm_gset.nim`. It is the
part-2 complement to the *dynamic* verification that lives in `../tests` (schedule
-hook interleavings, fork+SIGKILL fault injection, TSAN/ASan/UBSan, the LF-5 and
position-independence tests) and is wired through the `../Justfile`.

The dangerous bugs in this structure are memory-ordering and interleaving-window
defects that x86 stress passes for months and that only fault on ARM64, under a
rare schedule, at a different mmap base, or on an unlucky kill. Functional tests
alone give false confidence; hence this tier.

## What is RUNNABLE in this repo's dev shell (and was RUN)

| Artifact | Tool | Wired as | Result |
|---|---|---|---|
| Protocol model, IDENTITY key discipline | TLA+ / TLC (`nixpkgs#tlaplus`) | `just verify-tla` | **RAN — green.** 750 distinct states, depth 30, all invariants (incl. `ProbeRunComplete`) + 2 temporal props hold |
| Protocol model, KEYED discipline (multimap + tombstones + growth) | TLA+ / TLC | `just verify-tla` | **RAN — green.** 38,151 distinct states, depth 53 |
| Protocol model, flatten + retire vs a concurrent reader | TLA+ / TLC | `just verify-tla` | **RAN — green.** 51,375 distinct states, depth 71 |
| Valgrind DRD + helgrind | `valgrind` (dev shell) | `just test-valgrind` | **RAN — 0 errors** (both tools) |
| rr chaos record + replay | `rr` (dev shell) | `just test-rr` | **RAN — green.** Oracle held across 5 chaos schedules + 1 deterministic replay |
| Longer bounded soak | Nim (dev shell) | `just soak <secs>` | **RAN — green** (60 s: distinct=7200, growthFailures=0) |
| C11 atomics core, native | `gcc` (dev shell) | `core/` `-DSTANDALONE` | **RAN — green** (200000 slot-claim races) + TSAN clean |
| C11 atomics core, aarch64 | cross-gcc + `qemu-aarch64` | `core/build-aarch64-qemu.sh` | **RAN — green, FUNCTIONAL ONLY** (see caveat) |

### Coverage boundaries of the RUN items (read this)

- **TLC** explores **sequentially-consistent interleavings**. It proves the
  *logical* protocol is correct given correct ordering (no lost element, no
  phantom, exact union, chain integrity/no-lost-shard, idempotent dedup, grow
  arbitration, reaper flock safety, probe-run completeness, tombstone ordering,
  flatten/retire safety, liveness). It does **not** model ARMv8/RISC-V
  reordering — that is the litmus / GenMC job below.
- In the keyed model two further abstractions are deliberate: a producer's
  DECIDE step (scan the run, compute the generation to stamp) is atomic while its
  INSERT is step-wise (that is where the CAS race lives, and a stale decision is
  still modelled because other processes run in between); and the flattener
  copies one ELEMENT per step while the reader reads one SHARD per step (the
  reader property under test is about the order shards are visited in).
- **DRD / helgrind** (like TSAN) track shadow state by **virtual address**, and
  each thread/process `mmap`s the segment at its **own** base (the real multi-
  process shape), so they cannot observe the cross-mapping shared-segment
  ordering. They validate thread lifecycle, the process-global temp-name atomic
  (`gShardTmpSeq`), and the allocator. The cross-mapping release→acquire ordering
  is the litmus / GenMC / TLC job.
- **rr chaos** needs a hardware CPU-cycle counter. On Intel hybrid (P/E-core)
  parts rr's PMU probe fails unless pinned to one core — the runner passes
  `--bind-to-cpu` (override with `RR_BIND_CPU`).
- **qemu-aarch64** does **NOT** faithfully reproduce ARM weak memory. The aarch64
  run is a **functional** check (ABI, struct layout, atomic-builtin lowering,
  compile correctness) — it is **not** a weak-memory proof. Real ARM weak-memory
  coverage needs real hardware or the herd7 / GenMC artifacts below.

## What is AUTHORED but NOT RUN here (tool absent from this nixpkgs pin)

These are complete, ready-to-run artifacts. The exact `nix` attempts that failed
at authoring time (2026-07-16, this repo's pinned `nixpkgs`):

```
nix eval nixpkgs#herdtools7.name   -> attribute 'herdtools7' does not exist
nix eval nixpkgs#herd7.name        -> does not exist
nix eval nixpkgs#genmc.name        -> does not exist
nix eval nixpkgs#nidhugg.name      -> does not exist
nix eval nixpkgs#rcmc.name         -> does not exist
nix eval nixpkgs#cdschecker.name   -> does not exist
```

| Artifact | Tool needed | How to run once present |
|---|---|---|
| `litmus/*.litmus` (5 shipped-ordering + 1 relaxed control) | herd7 (`herdtools7`) | `nix shell nixpkgs#herdtools7 --command litmus/run-litmus.sh` |
| `core/shm_gset_core.c` under a stateless model checker | GenMC / Nidhugg / CDSChecker | `nix shell nixpkgs#genmc --command genmc -- -unroll=3 core/shm_gset_core.c` (or `nidhugg --c11 --unroll=3 …`) |

The litmus tests encode, per hardware model (x86-TSO, ARMv8, RISC-V), the exact
release→acquire message-passing shape of every publish pair: slot publish, arena
-offset follow, header-magic attach, shard-link, chain-bump. Each shipped test's
`exists` clause must be **Forbidden** ("Never"); the `-RELAXED-control` companion
must be **Allowed** on a weak model, which is what proves the shipped ordering is
load-bearing (the "passes on x86, faults on ARM" trap).

The C11 core (`core/shm_gset_core.c`) is the **same memory orders** the Nim
library uses (`memory_order_release` slot CAS, `seq_cst` arena bump, `acq_rel`
chain-bump, `acquire` reader loads) on a tiny forced-collision table with two
producers — the compilation unit a model checker drives, matching the shipped
algorithm rather than paraphrasing it.

## The two protocol models

`tla/shm_gset.tla` models the **identity** key discipline (`ShmGSetT[IdentityKey]`,
io-mon): the element is its own key, membership only. `tla/shm_gset_keyed.tla`
models the **keyed** discipline (`primaryKeySpan` selects a sub-range of the
element, so a whole SET of elements shares one home slot) with tombstone
eviction, a global generation counter, flattening and retirement — the discipline
`reprobuild-specs/Action-Cache-Per-Edge-Store.md` §6.1–6.7 specifies.

The keyed module's invariants, and what each is for:

| Invariant | Establishes |
|---|---|
| `RunEnumerationExact` | Per shard, the walk from `Home[k]` to the first empty slot, filtered on the stored key, **equals** the set of that key's published elements. `⊆` is "no phantom in the run"; `⊇` is "no element missed, no early termination". |
| `RunIntegrityAcrossShards` | Growth splits a key's elements across shards; enumeration over the union of per-shard walks is still exactly the key's element set. |
| `EnumerationDecidesLikeUnion` | The liveness verdict reached through the probe run equals the verdict an omniscient observer reaches from every published element. |
| `GenerationInvariant` | Every stamped generation is dominated by the single global counter in shard0 — what makes "newer" a total order across the whole chain. |
| `EvictionEffective` / `PutEffective` | After an eviction completes the key reads dead; after a put completes it reads live — in every interleaving, across shard boundaries, and regardless of what other keys did in the same probe run. |
| `FlattenDrainsOnlyCopied` | A shard is marked drained **only** in states where every element it holds is also present in a live shard. |
| `ReaderCompleteUnderFlatten` | A reader walking the chain oldest-shard-first, concurrently with copy-forward / drain / unlink, finishes having seen everything observable when its walk began. |
| `ObservabilityMonotone` (action) | Nothing observable ever becomes unobservable — the grow-only property surviving both eviction and flattening. |

### Both models were checked for VACUITY, not just for green

A green run over a workload that never reaches the interesting states proves
nothing. The flatten configuration was verified to actually flatten by asserting
the **negation** of each behaviour of interest as an invariant and confirming TLC
reports a violation (scratch copies; the probes are not shipped in the configs):

```
NoGrowProbe     == chain < 3                    -> violated (the chain does grow)
NoDrainProbe    == \A s \in Shards : ~drained[s] -> violated (a flatten does drain)
NoRetireProbe   == ...                           -> violated (a shard is retired)
NoReadDoneProbe == ~rdone                        -> violated (the reader completes)
```

The first version of that configuration passed everything **vacuously** — four
elements at `Cap = 2` filled two shards without ever opening a third, so
`Flattenable` stayed empty and the flattener never ran. The shipped workload has
five distinct elements and was re-checked against all four probes.

### `ReaderCompleteUnderFlatten` has teeth (the shard order is load-bearing)

Flipping the reader to walk **newest-shard-first** and re-running the same
configuration makes TLC report `Invariant ReaderCompleteUnderFlatten is violated`
after ~29k states: the flattener copies an element forward *after* the reader has
passed the destination and drains the source *before* the reader reaches it, so
the reader sees it in neither. This is why `withPrimaryKeyHash`, `contains` and
`items` all walk shards in **ascending** index order.

## Files

- `tla/shm_gset.tla` — PlusCal model of the identity discipline + embedded TLA+
  translation + invariants.
- `tla/shm_gset_MC.{tla,cfg}` — the finite TLC instance (3 elements, 2-slot shard,
  forced grow) and its config.
- `tla/shm_gset_keyed.tla` — PlusCal model of the keyed discipline (multimap,
  tombstones, global generation counter, flatten + retire, concurrent reader).
- `tla/shm_gset_keyed_MC.{tla,cfg}` — two racing producers over two primary keys
  that SHARE a home slot, with a put/evict/resurrect cycle; no flatten.
- `tla/shm_gset_keyed_flat_MC.{tla,cfg}` — one producer, flattener and reader, at
  `Cap = 2` so the chain really grows and shard 2 really becomes flattenable.
- `litmus/*.litmus` — herd7 litmus tests (+ `run-litmus.sh`).
- `core/shm_gset_core.c` — extracted C11 atomics core (+ `build-aarch64-qemu.sh`).
- `run-rr-chaos.sh` — rr chaos record/replay driver (used by `just test-rr`).
