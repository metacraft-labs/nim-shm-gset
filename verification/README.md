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

## Every `just verify-*` tool is PINNED by this repo's own flake

Until 2026-08-21 the tools in this directory were pulled ad hoc with
`nix shell nixpkgs#tlaplus` / `nix shell nixpkgs#pkgsCross...`, which resolves
through the machine's mutable **flake registry** — whatever nixpkgs that
machine last synced. For a directory whose entire product is verification
*evidence*, that is a defect in the evidence itself: two runs on two days are
not the same experiment.

`../flake.nix` now pins nixpkgs (`0c88e1f2`, the revision every result below was
produced against) and **packages the four checkers nixpkgs does not carry** —
herdtools7, GenMC, Nidhugg and CDSChecker — in `../nix/*.nix`. `../flake.lock`
is committed; that is the whole point. Every `just verify-*` target runs through
it. A second, separately pinned nixpkgs (`ac62194c`) exists for exactly one
package: Nidhugg only offers its ARM memory model when built against LLVM ≤ 15,
and the primary pin has removed `llvmPackages_14/15/16` as obsolete. (What that
buys and does not buy is recorded under "Coverage boundaries" below — the answer
is honest and disappointing.)

`gcc15Stdenv`, not the pin's default gcc 14, is also load-bearing: gcc 14's TSAN
runtime dies on this kernel's address-space layout with
`FATAL: ThreadSanitizer: unexpected memory mapping`, which would have silently
cost `just verify-core` its §4.5(g) leg. (Re-checked against the pin's own
gcc 14.3.0: compiles fine, then exits 66 on that FATAL before a single
iteration.)

The boundary is *almost* exactly `verify-*`. `just test`, `just soak`,
`just bench` and `test-sanitizers` deliberately keep
using the AMBIENT workspace toolchain, end to end — that is what a developer
edits against all day, and io-mon consumes this repo as a plain source path
compiled by io-mon's own Nim. The rows below that say "(dev shell)" mean that
ambient toolchain, not the flake. `nix develop . -c just test` also works and
gives the same **101 `[OK]` / 0 `[FAILED]` / 0 `[SKIPPED]`** (re-measured
2026-08-22); it is simply not forced. That count sat stale at 97 for two rounds
while the suite grew to 100 and then 101 — if you change the suite, re-measure
it here and in the `Justfile` header rather than carrying the old one forward.

**There are TWO runners, and until now they ran different suites.** The
`test` recipe in the `Justfile` and the `test` task in `shm_gset.nimble` are
both entry points to the same suite, and both files carried comments asserting
the rule that a required milestone test must not be reachable from one runner
only. Nothing checked it, and it was false: measured 2026-08-22, `just test`
reported **101 `[OK]`** and `nimble test` **85**. The missing 16 were four whole
files registered in the `Justfile` alone —
`tests/test_shm_gset_concurrency.nim` (9: the §4.5 SIGKILL fault-injection
battery at `spBeforeSlotCas` / `spBeforeArenaPublish` / `spBeforeShardLink` /
`spBeforeChainBump`, concurrent double shard-link with no leaked file,
position-independence at a different mmap base, the arena release-publish
visibility case, and the reaper `flock` race), `test_shm_gset_transport.nim`
(4: the LF-1 union gate and the LF-2 `emUnavailable` / `emOversize`
fail-fasts), `test_shm_gset_lf5.nim` (2) and `test_shm_gset_threads.nim` (1,
which is also the compilation unit `test-sanitizers` and `test-valgrind`
build under TSAN / helgrind / DRD). It went unseen for months for a mundane
reason: `nimble` was in neither the workspace shell nor this flake, so
`nimble test` exited 127 and the task had only ever been reviewed by READING.
`nimble` is in `flake.nix` now, the four files are registered, and both runners
measure **101 / 0 / 0** over the same test-name set.

That is a fix, not a guard, so there is a guard too:
`scripts/check-runner-parity.sh` re-derives from both files the set of
`tests/*.nim` each runner compiles AND the flag set each is compiled with, and
fails on any difference — plus on a `tests/test_*.nim` on disk that neither
runner builds. It runs as the first step of the `Justfile` `test` recipe (via
`just check-runner-parity`) and as the first `exec` of the nimble task, so
neither runner can be used while they disagree. Flags are compared, not just
file names, because a file built with `-d:shmGSetScheduleHooks` under one runner
and without it under the other is a silently WEAKER run that both runners would
still report with the same `[OK]` count. It fails CLOSED: a recipe or task it
cannot parse (zero compiles found) is an error, never a pass. Mutation-checked
five ways — dummy test file in the `Justfile` only, in the nimble task only, on
disk in neither, a flag-only divergence (`-d:shmGSetScheduleHooks` dropped from
one side), and a renamed nimble task yielding zero parsed compiles — each exits
1 on the assertion it names, with the tree restored and re-verified green by
checksum afterwards.

**`test-valgrind` is the exception, and this paragraph used to get it wrong.**
It was described here and in the `Justfile` as an ambient target, but `valgrind`
is not in the workspace shell — it is in *this repo's* `flake.nix`, moved there
when the §4.5(g) dynamic tier was pinned, and neither doc followed it. Measured
on a bare workspace shell: `just test-valgrind` exited **127** with
`sh: line 1: valgrind: command not found`, so the target had been documented as
runnable where it was not. Fixed in the recipe rather than only in the prose:
`test-valgrind` still BUILDS its binaries with the ambient nim (the build a
developer actually produces) and now invokes the valgrind BINARY through the
pinned flake, so `just test-valgrind` works from a bare workspace shell —
re-measured after the change, exit 0, helgrind and DRD 0 errors, memcheck
`All heap blocks were freed`. Rows below that name valgrind therefore say
"(pinned flake)".

**`test-rr` was the same defect, found by re-running the same measurement.**
Both this file and the `Justfile` asserted that `rr` is ambient — the `Justfile`
went further and said it is "genuinely ambient (it is in the user profile)". A
user profile is not the workspace toolchain: measured on a bare workspace shell,
`command -v rr` is EMPTY and `just test-rr` failed with
`verification/run-rr-chaos.sh: line 40: rr: command not found` /
`FAIL: rr record iteration 1 exited 127`. Unlike valgrind nothing had to move —
`rr` was already in this repo's `flake.nix`; only the wiring was missing.
`verification/run-rr-chaos.sh` now resolves the rr BINARY from the pinned flake
(ONE resolution shared by record and replay, because a trace can only be replayed
by the rr that recorded it; `SHM_GSET_RR` overrides) while still building the
soak harness with the ambient nim. Re-measured after the change: green from the
ambient shell AND from a bare workspace shell.

```
just verify            # the whole tier
just verify-tla        # TLC, 5 models
just verify-core       # native C11 cores + the RELAXED_SEAL control + TSAN
just verify-litmus     # herd7: 44 C11-model checks + 11 hardware-model checks
just verify-models     # GenMC + Nidhugg over the real C11 cores
just verify-cdschecker # CDSChecker over ported publish/handshake shapes
just verify-aarch64    # cross-build + qemu-user (FUNCTIONAL only)
```

## What is RUNNABLE in this repo's dev shell (and was RUN)

| Artifact | Tool | Wired as | Result |
|---|---|---|---|
| Protocol model, IDENTITY key discipline | TLA+ / TLC (pinned flake) | `just verify-tla` | **RAN — green.** 750 distinct states, depth 30, all invariants (incl. `ProbeRunComplete`) + 2 temporal props hold |
| Protocol model, KEYED discipline (multimap + tombstones + growth) | TLA+ / TLC | `just verify-tla` | **RAN — green.** 38,151 distinct states, depth 53 |
| Protocol model, flatten + retire vs a concurrent reader | TLA+ / TLC | `just verify-tla` | **RAN — green.** 51,375 distinct states, depth 71 |
| **Recycling POOL under N in-flight actions (HM-3)** | TSAN (dev shell) | `just test-sanitizers` | **RAN — 0 races.** Not about the segment's atomics: about the pool's own Nim-level state. It EARNED its place — the pool was first a `ref object`, on which TSAN reports **races on the pool's own refcount** (`nimIncRef`/`nimDecRef` from `acquire`/`release` in two worker threads; ORC counters are atomic only under `-d:gcAtomicArc`), and which crashed in the runtime intermittently — a minority of whole-file runs, sampled between roughly one in six and one in eight — while passing every functional assertion. **The gate is NONZERO vs ZERO, not a count:** TSAN reports per observed schedule, so the number of races on a `ref` build is not a specification, exactly as the `-DRELAXED_SEAL` control's straddle counts are not. The shipped `ptr` + lock-guarded GC'd fields is clean |
| Valgrind DRD + helgrind | `valgrind` (pinned flake; binaries built ambient) | `just test-valgrind` | **RAN — 0 errors** (both tools) |
| **Pool lifecycle leak gate (HM-3)** | `valgrind` memcheck (pinned flake; binary built ambient) | `just test-valgrind` | **RAN — 0 errors, all heap blocks freed.** `tests/helpers/pool_lifecycle_probe.nim` under `--leak-check=full --errors-for-leak-kinds=definite`. NOT a race check: `SetPoolObj` is `allocShared0` memory with no destructor, so a GC'd field merely TRUNCATED before `deallocShared` is orphaned — 136 bytes definitely lost PER POOL. Quote the per-pool figure, not a whole-program one: `pool_lifecycle_probe.nim` drives TWO pool lifecycles, so reverting the fix measures **272 bytes definitely lost in 2 blocks, `ERROR SUMMARY: 2 errors from 2 contexts`**, exit 99 — the "1 error from 1 context" recorded during the original diagnosis came from a one-pool scratch program that is not what this gate runs |
| rr chaos record + replay | `rr` (pinned flake; harness built ambient) | `just test-rr` | **RAN — green.** Oracle held across 5 chaos schedules + 1 deterministic replay |
| Longer bounded soak | Nim (dev shell) | `just soak <secs>` | **RAN — green** (60 s: distinct=7200, growthFailures=0) |
| C11 atomics core, native | `gcc` (dev shell) | `core/` `-DSTANDALONE` | **RAN — green** (200000 slot-claim races) + TSAN clean |
| C11 atomics core, aarch64 | cross-gcc + `qemu-aarch64` | `core/build-aarch64-qemu.sh` | **RAN — green, FUNCTIONAL ONLY** (see caveat) |
| **Reset/recycling protocol (HM-2)** | TLA+ / TLC | `just verify-tla` | **RAN — green.** 901 distinct states, depth 18, 5 safety invariants + 1 temporal property. `just verify-tla` is 4/4 green end to end (750 / 38 151 / 51 375 / 901 distinct states), exit 0 |
| **Host-side recycling POOL lifecycle (HM-3)** | TLA+ / TLC | `just verify-tla` | **RAN — green.** 7,444 distinct states, depth 15, 8 safety invariants + 1 temporal property. `just verify-tla` is 5/5 green end to end. See "The pool model has teeth" below for the three switched-off mutations and the seven vacuity probes |
| **Reset/recycling C11 core, native** | `gcc` | `just verify-core` | **RAN — green** (100 000 barrier-synchronised reset-vs-insert races) + TSAN clean |
| **Reset core, `-DRELAXED_SEAL` control** | `gcc` | `just verify-core` | **RAN — FAILS AS INTENDED** on x86-64. **NO RANGE IS QUOTED HERE, deliberately — see "why this row no longer states a band" below.** The claim this row supports is qualitative and is the whole of it: the SHIPPED build produces **zero** straddles and **zero** cross-generation leaks; the `-DRELAXED_SEAL` control produces **nonzero on at least one of its two counters** — in practice single to low-double digits per 100 000. Do not read that as "nonzero on both": the independent verification run of 2026-08-22 measured **0 straddles and 39 cross-generation leaks per 100 000** on this machine, so a per-counter zero is not hypothetical, it has been observed. The gate is the DIRECTION, nonzero versus zero, never a count. A **zero from the control is INCONCLUSIVE, not a pass**: the control is a SAMPLER, and the leg that DECIDES this hazard is GenMC (`just verify-models`), which finds it exhaustively under RC11 and returns a counterexample |
| **Reset core, aarch64** | cross-gcc + `qemu-aarch64` | `just verify-aarch64` | **RAN — green, FUNCTIONAL ONLY** |
| **Litmus, C11 language model** | herd7 7.58 (packaged here) | `just verify-litmus` | **RAN — 44/44 as declared.** 11 tests × 4 C11 models (`c11_partialSC`, `c11_orig`, `c11_simp`, `rc11`); every shipped test Never, every `-RELAXED-control` Sometimes |
| **Litmus, ARMv8 / RISC-V / x86-TSO hardware models** | herd7 7.58 | `just verify-litmus` | **RAN — 11/11 as declared.** See the table below; this is the ARMv8 coverage qemu-user could not give |
| **Insert C11 core under a stateless model checker** | GenMC 0.17.0 (packaged here) | `just verify-models` | **RAN — green.** 12 complete executions under RC11, no errors |
| **Reset C11 core (HM-2) under a stateless model checker** | GenMC 0.17.0 | `just verify-models` | **RAN — green.** 30,504 complete + 5,808 blocked executions under RC11, no errors |
| **Reset core `-DRELAXED_SEAL` under a stateless model checker** | GenMC 0.17.0 | `just verify-models` | **RAN — FAILS AS INTENDED, with a counterexample.** `Error: Safety violation!` on the straddle oracle, with the full execution graph. This is the **`m6`** result: see below |
| **Insert C11 core, second independent checker** | Nidhugg 0.4 (packaged here) | `just verify-models` | **RAN — green** under `--sc` (6 traces), `--tso` (12), `--pso` (12). Weaker corroboration than the trace counts suggest — read the Nidhugg bullet under "Coverage boundaries" before quoting this row |
| **Publish + handshake shapes, third independent checker** | CDSChecker (packaged here) | `just verify-cdschecker` | **RAN — 3 of 4.** slot-publish shipped clean; slot-publish RELAXED control correctly buggy (1); seal-vs-register shipped clean. The seal RELAXED control does not run — CDSChecker aborts; see below |

### The litmus results, per hardware model

`just verify-litmus`, tier 2. Every one matched the expectation declared in its
own file.

| Test | Model | Result |
|---|---|---|
| `arch/MP-shipped.AArch64` (STR,STR,STLR / LDAR,LDR,LDR) | `aarch64.cat` | **Never** — forbidden |
| `arch/MP-relaxed.AArch64` (all plain) | `aarch64.cat` | **Sometimes** — ALLOWED |
| `arch/MP-shipped.RISCV` (`fence rw,w` / `fence r,rw`) | `riscv.cat` | **Never** |
| `arch/MP-relaxed.RISCV` (no fences) | `riscv.cat` | **Sometimes** — ALLOWED |
| `arch/MP-both-lowerings.X86` | `x86tso.cat` | **Never** for BOTH lowerings — the trap, made explicit |
| `arch/SB-sc.AArch64` (STLR / LDAR) | `aarch64.cat` | **Never** |
| `arch/SB-relacq.AArch64` (STLR / LDAPR) | `aarch64.cat` | **Sometimes** — ALLOWED |
| `arch/SB-sc.RISCV` (`fence rw,rw`) | `riscv.cat` | **Never** |
| `arch/SB-relacq.RISCV` | `riscv.cat` | **Sometimes** — ALLOWED |
| `arch/SB-sc.X86` (MFENCE) | `x86tso.cat` | **Never** |
| `arch/SB-relacq.X86` (no fence) | `x86tso.cat` | **Sometimes** — ALLOWED, on x86 |

Three things this settles that nothing else in the repo did:

1. The seven shipped publish pairs are forbidden on **real ARMv8 and RISC-V**,
   not merely at the C11 language level.
2. Downgrading them is **allowed on ARMv8 and RISC-V and forbidden on x86** —
   the same C source, the same bug, invisible on the machine this repo is
   developed on. That asymmetry is now demonstrated rather than asserted.
3. The seal/registry handshake's release/acquire downgrade is allowed on **every
   model including x86-TSO**, which is why those four accesses (and only those)
   are `seq_cst`.

These eleven are hand-written, so they were MUTATION-CHECKED rather than
trusted — each mutation on a scratch copy, none of them shipped:

| Mutation | Verdict | Shows |
|---|---|---|
| `MP-shipped.AArch64`: `STLR`→`STR`, `LDAR`→`LDR` | Never → **Sometimes** | the barriers carry the result; the `exists` clause is not simply unsatisfiable |
| `SB-sc.X86`: drop `MFENCE` | Never → **Sometimes** | x86-TSO really does permit SB; the fence is the whole result |
| `SB-sc.AArch64`: `LDAR`→`LDAPR` | Never → **Sometimes** | the RCsc/RCpc distinction below is real, measured in this direction |
| `SB-relacq.AArch64`: `LDAPR`→`LDAR` | Sometimes → **Never** | …and in the other. The shipped control does use `LDAPR` |

One subtlety is recorded in `arch/SB-relacq.AArch64.litmus` rather than glossed:
ARMv8 has two acquire loads. With `LDAPR` (RCpc, the acquire C11
release/acquire actually entitles an implementation to use) the bad outcome is
**Sometimes**. With `LDAR` (RCsc, what mainstream compilers currently emit) it is
**Never** — that lowering accidentally gives the weaker program seq_cst
behaviour. Verified both ways. It is not a licence to weaken the code: the code
must be correct for every conforming lowering, and C11 itself says Sometimes.

### `m6`: what GenMC closed that TLA+ could not state

`tla/shm_gset_reset.tla` makes `PAttach` a single atomic step, so the model
literally cannot express "a producer claimed a registry entry and then missed
the seal" — the two halves of the Dekker handshake are one action there. The
C11 core is the real thing (`attach()` is CAS-the-entry, *then* load the seal),
and GenMC explores it under RC11:

```
$ genmc -disable-ipr -unroll=5 -- -std=c11 -DRELAXED_SEAL core/shm_gset_reset_core.c
Error: Safety violation!
  ...
  (2, 14): UWsc (straddles, 1)          shm_gset_reset_core.c:261
  (0, 37): Rsc  (straddles, 1) [(2,14)] shm_gset_reset_core.c:360
  (0, 38): ERROR                        shm_gset_reset_core.c:360
```

i.e. a producer held an attach across a generation change — the exact
cross-attribution HM-2 exists to prevent — with a concrete execution graph
rather than a probability. Line 261 is the straddle counter in `producer()`,
line 360 the quiescence assertion in the model-checker `main()`; the violated
property is the QUIESCENCE oracle, not (in this particular graph) the
per-record cross-generation one. The shipped build over the same 30,504
executions finds none.

Two edits to `core/shm_gset_reset_core.c` were needed to make that control
meaningful, both confined to the model-checker path:

- `GEN_ORACLE` counted leaks instead of asserting under `RELAXED_SEAL`. That is
  right for the native hammer (which wants a frequency) and **wrong** under a
  stateless checker, where there is one symbolic run and the question is
  reachability: the checker would have reported "no errors" on the control and
  the control would have proved nothing. It now counts only under `STANDALONE`.
- The model-checker `main()` now asserts `straddles == 0`, the quiescence
  property the native build could only print at the end.

Neither changes the native `-DSTANDALONE` behaviour. That is not an assertion:
preprocess `core/shm_gset_reset_core.c` before and after with `-DSTANDALONE`
and with `-DSTANDALONE -DRELAXED_SEAL` and the two translation units are
IDENTICAL once `__assert_fail`'s file/line arguments are normalised. Only the
two model-checker configurations (no `STANDALONE`) differ, and both differ by
being STRICTLY STRONGER — an oracle that counted now asserts, plus one added
assertion. Nothing was weakened, and no configuration the shipped build uses
changed at all.

### Coverage boundaries of the RUN items (read this)

- **TLC** explores **sequentially-consistent interleavings**. It proves the
  *logical* protocol is correct given correct ordering (no lost element, no
  phantom, exact union, chain integrity/no-lost-shard, idempotent dedup, grow
  arbitration, reaper flock safety, probe-run completeness, tombstone ordering,
  flatten/retire safety, liveness). It does **not** model ARMv8/RISC-V
  reordering — that is the litmus / GenMC job below.
- In the RESET model two abstractions are deliberate, and each is stated so the
  model is not read as proving more than it does: linear probing is abstracted
  to "claim SOME slot that is not live under the generation this producer read"
  (probe-run completeness is already proven by `shm_gset.tla`, and which slot is
  claimed is irrelevant to every reset invariant), and each producer attaches
  and inserts exactly once, which keeps the state space finite. What is NOT
  abstracted away: a producer may attach at ANY unsealed moment, including after
  the consumer has marked itself gone, so both the "blocks the reset" and the
  "fast-fails on the liveness token" paths are explored rather than assumed
  away by a host-lifecycle assumption.
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
- The **`-DRELAXED_SEAL` control is the strongest evidence in this directory**,
  because it is demonstrated on real silicon rather than only modelled (it is
  now also demonstrated exhaustively under GenMC/RC11, which is what makes the
  claim independent of this machine's timing).
  The seal/registry handshake is a **store-buffer (Dekker)** shape, not a
  message-passing one, so x86-TSO does *not* rescue it: downgrading the four
  accesses from `seq_cst` to release/acquire reproduces the exact hazard —
  an attached producer straddling a reset, and its record then read under the
  wrong generation — on this x86-64 machine, within 100 000 runs, while the
  shipped build shows zero of both. Under `qemu-aarch64` the control reports
  ZERO, which is a limitation of qemu-user (see below), not a contradiction.
  **But the native control is PROBABILISTIC, and thinner than it looks.** Runs
  have come back with a SINGLE straddle in 100 000 — so a quieter machine, a
  different core count, or a different scheduler could plausibly return zero and
  make the control look like it had passed. Treat a zero from
  `just verify-core`'s control as "inconclusive, re-run under load", never as
  "the ordering does not matter". The claim does NOT rest on this:
  `just verify-models` demonstrates the same hazard EXHAUSTIVELY under GenMC/
  RC11, where "reachable" is decided rather than sampled, and that is the leg
  that makes the result independent of this machine's timing.

  **Why this row no longer states a band.** It used to, three times over, and
  every one was blown through by the next independent sampling:

  | # | band recorded (straddles / leaks per 100 000) | how it died |
  |---|---|---|
  | 1 | 13–27 / 86–166 | over-tightened; next sampling fell outside |
  | 2 | 9–26 / 55–109 | over-tightened; next sampling fell outside |
  | 3 | 1–43 / 52–158 | FOUR consecutive independent runs came in at **2 / 42**, **1 / 39**, **4 / 50** and **0 / 39** — every one below the leak floor of 52, and the fourth below the straddle floor of 1 as well |

  Each band was correctly LABELLED an observation and correctly carried the
  "a zero is inconclusive" caveat, so none of them was a correctness bug. The
  problem is structural and is why the practice stops here rather than being
  re-tightened a fourth time: the control's event rate is a function of the load
  average, core count and scheduler *at the instant of the run*, so a
  ten-sample band bounds THAT machine in THAT moment, not the mechanism — and
  writing it down converts an observation into a number the next honest run is
  obliged to contradict. It also invites exactly the wrong reading, that a run
  landing inside the band is a pass and one outside it is a regression, when the
  only thing the sampler can say is nonzero versus zero. Report the pair of
  counts the run actually produced if it is useful; do not turn a fresh sample
  into a range. The leg that DECIDES is GenMC.

  The fourth of those runs is worth naming on its own, because it is the case
  this section had only ever described as *plausible*: the independent
  verification run of 2026-08-22 returned **0 straddles** and 39 leaks. The
  straddle counter — the one the GenMC control keys on — came back CLEAN from a
  build that is provably broken. Nothing was wrong with the run and nothing is
  wrong with the mechanism; it is the sampler doing exactly what a sampler does,
  and it is the concrete reason "treat a zero as inconclusive" is a rule here
  rather than a hedge.
- **qemu-aarch64** does **NOT** faithfully reproduce ARM weak memory. The aarch64
  run is a **functional** check (ABI, struct layout, atomic-builtin lowering,
  compile correctness) — it is **not** a weak-memory proof. Real ARM weak-memory
  coverage is now the herd7 `arch/*.AArch64.litmus` tier plus GenMC's RC11 run;
  see "The ARM64 requirement" below for what that does and does not settle.
- **herd7 on the `C` tests answers a LANGUAGE question, not a hardware one.**
  herd7 checks a `C` litmus test against a C11 model and *refuses* to check it
  against `aarch64.cat` / `riscv.cat` / `x86tso.cat` — a cat model is tied to one
  architecture. Forbidden under C11 is the stronger statement for the shipped
  orderings (no conforming implementation on any target may permit it), but it
  cannot distinguish "x86 hides this" from "ARM exposes it", which is exactly
  what the `-RELAXED-control` pairs are for. Hence the two tiers.
  Known wart, left alone deliberately: several `litmus/*.litmus` headers still
  word their `EXPECTED:` line as "herd7 `-model aarch64` / `riscv`", an
  invocation that (per the paragraph above) cannot be run for a `C` test. The
  VERDICTS those headers declare — Never for every shipped test, Sometimes for
  every control — are the ones `run-litmus.sh` checks and the ones herd7
  returns, and no annotation was edited to match a measurement. Only the
  invocation wording is stale; the per-architecture answer now lives in
  `litmus/arch/`.
- The MP tests carry `Flag *undef*` under the C11 models. That is honest and
  expected: the litmus reader loads the payload **unconditionally**, so in the
  execution where it observes the flag as 0 there is a plain/plain data race.
  The shipped reader only follows a published, non-zero slot. The `Observation`
  line is unaffected.
- **GenMC** checks under **RC11**, which is a language-level model, not an
  architecture one. That is a feature rather than a gap for the shipped code:
  the compilation schemes from RC11 to ARMv8 and to x86-TSO are proven sound, so
  a program with no RC11 violation has none under either target given the
  standard lowering. It is *not* a substitute for running on ARM64 silicon,
  which would also exercise the compiler, the kernel and the allocator.
- **Nidhugg's ARM model is packaged but unusable on these cores**, and the
  reason is worth recording rather than omitting. Nidhugg is deliberately built
  against LLVM 15 (it refuses `--arm` for LLVM ≥ 16) purely so `--arm` is
  selectable at all — and it then rejects the program:
  `Error: Unsupported instruction: %12 = atomicrmw add i32* %7, i32 1 seq_cst`.
  Its ARM/POWER trace builders do not support read-modify-writes, and the core's
  arena bump and slot CAS are both RMWs. (It also warns that its ARM model
  predates LLVM 15's opaque pointers, so even an RMW-free program would be on
  thin ice there.) Nidhugg therefore contributes `--sc`/`--tso`/`--pso`
  corroboration only.
- **And that `--tso`/`--pso` corroboration is weaker than a trace count makes it
  look**, which matters because Nidhugg is the whole justification for the
  second nixpkgs pin. Both runs print
  `WARNING: Non-sequentially consistent CMPXCHG instruction interpreted as
  sequentially consistent`, i.e. Nidhugg silently STRENGTHENS the core's
  `acq_rel` slot-claim and arena-reserve CASes to `seq_cst` before exploring.
  So what those 12+12 traces certify is a strengthened program, not the shipped
  memory orders; `--sc` certifies a strengthened one by definition. The real
  weak-memory verdicts on the shipped orders come from GenMC/RC11 and herd7.
  Nidhugg's honest contribution is "a second, independently implemented
  explorer finds no interleaving bug in the same source" — worth having, but not
  worth much of a second nixpkgs pin. Keeping the LLVM-15 pin is a bet that
  upstream will lift the RMW restriction; if that has not happened next time
  this file is revisited, drop `nixpkgs-llvm15` and build Nidhugg from the
  primary pin.
- **CDSChecker aborts on one of the four cases**, in its own machinery rather
  than on anything this repo wrote: `seal-vs-register.c -DRELAXED_SEAL` dies
  with `SIGSEGV in mspace_malloc` / `*** buffer overflow detected ***`,
  reproducibly, on a plain non-Nix build of upstream master too, at every
  bounding option, and with pure-relaxed orders as well. Its 2014-era
  snapshotting allocator does not survive a 2025 glibc on this program. The
  other three cases run, including the *other* control, so this is specific
  rather than a broken package. That property is covered four other ways —
  herd7 C11 (4 models), herd7 hardware models (3 archs), GenMC's counterexample,
  and real x86-64 silicon.

### The ARM64 requirement (§4.5): what is now satisfied, and what is not

Stated precisely, because the previous "qemu functional only" wording made this
look worse than it was and the current position must not make it look better.

| §4.5 ARM64 obligation | Status |
|---|---|
| Every release→acquire pair proven under the **ARMv8 memory model** | **SATISFIED.** `arch/MP-shipped.AArch64.litmus` and `arch/SB-sc.AArch64.litmus`, Forbidden under `aarch64.cat`. |
| The controls proven **ALLOWED** on ARMv8, so the shipped ordering is shown to be load-bearing there and not just on paper | **SATISFIED.** `arch/MP-relaxed.AArch64` and `arch/SB-relacq.AArch64`, Sometimes. |
| The full C11 core checked under a model sound for ARMv8 | **SATISFIED via GenMC/RC11**, with the caveat above: RC11 entails ARMv8 under the proven lowering; it does not exercise a real ARM64 compiler or kernel. |
| The full C11 core checked under an explicit **ARM hardware** model | **NOT satisfied.** Nidhugg `--arm` rejects the core's RMWs (above). No packaged tool can do this today. |
| §4.5(f) **multi-hour randomized soak on ARM64**, comparing against the oracle | **NOT satisfied, and not satisfiable here.** This needs ARM64 silicon (hardware or a CI runner). qemu-user gives functional coverage only. |
| The Nim library itself (not just the C11 core) exercised on ARM64 | **NOT satisfied.** There is no aarch64 Nim toolchain wired up; `build-aarch64-qemu.sh` cross-builds the C cores only. |

The honest summary: the ARM64 **memory-ordering** obligation is now met
formally, which is what the "passes on x86, faults on Apple silicon" risk
actually turns on. The ARM64 **execution** obligations — soak, real toolchain,
real kernel — remain open and still need hardware.

## Formerly "AUTHORED but NOT RUN" — now packaged and run

The four checkers really are absent from nixpkgs, at this pin and at the 25.05
release. Verified by grepping the nixpkgs source tree itself, not by a single
`nix eval`: no `herdtools7`, no `herd7`, no `ocamlPackages.herdtools7`, no
`genmc`, no `nidhugg`, no `cdschecker`. So they are **packaged in this repo**,
in `../nix/`, and wired into `../flake.nix`:

| Tool | Version | What packaging it needed |
|---|---|---|
| **herd7** (`nix/herdtools7.nix`) | 7.58 | OCaml 5.3 + dune + menhir + **menhirLib** + zarith, `which` for upstream's `check-deps`, and a writable `HOME` for dune's cache. `PREFIX=$out` at BUILD time, not just install time — `version-gen.sh` bakes the `.cat` model search path into `Version.ml`. |
| **GenMC** (`nix/genmc.nix`) | 0.17.0, LLVM 19 | Two upstream lookups assume llvm, llvm-dev and clang share one prefix (`find_program(... PATHS ${LLVM_TOOLS_BINARY_DIR} NO_DEFAULT_PATH)`); nixpkgs splits all three, so both are pointed at exact store paths. **`CMAKE_INSTALL_INCLUDEDIR=include` is load-bearing**: nixpkgs passes it absolute, upstream concatenates it onto `CMAKE_INSTALL_PREFIX`, and the resulting `$out/$out/include/...` made clang silently fall back to the SYSTEM `<pthread.h>` — every run then died with `Tried to execute an unknown external function: pthread_create`. The driver also installs to `bin/genmc/genmc` and has to be flattened onto PATH. |
| **Nidhugg** (`nix/nidhugg.nix`) | 0.4 @ `0aea4d23`, **LLVM 15** | autoreconf; `--with-boost-libdir` because nixpkgs splits boost `dev`/`out` and the `ax_boost_*` macros assume one prefix; `--with-clang`/`--with-clangxx` (configure aborts otherwise). Built from a **second pinned nixpkgs** solely because `--arm` needs LLVM ≤ 15 and the primary pin removed `llvmPackages_15`. |
| **CDSChecker** (`nix/cdschecker.nix`) | `bdemsky/cdschecker` @ `3de23e75` | One patch: `-std=gnu++11`, because the 2014 sources use `throw(std::bad_alloc)` dynamic exception specifications that C++17 removed. Its replacement headers are installed to `$out/share/cdschecker/include`, **not** `$out/include` — in `$out/include` `mkShell`'s `-isystem` made every ordinary `cc` in the repo pick up CDSChecker's `<stdatomic.h>`, and `just verify-core` failed to link with `undefined reference to model_write_action`. |

### The litmus files did not parse, and nobody had noticed

The `C` litmus tests used OCaml-style `(* … *)` comments **inside the P0/P1
program bodies**. herd7's C lexer rejects them:

```
Warning: File "slot-publish.litmus", line 26, characters 68-74:
         unexpected 'record' (in prog) (User error)
```

Every one of the eight shipped tests and three controls failed to parse. They
are now `/* … */` inside bodies (init-block comments stay `(* … *)`, which is
what herd7's *init* lexer wants — converting those too broke
`reset-rearm-publish.litmus` with `Lex error Init lex`). No `exists` clause, no
memory order and no EXPECTED annotation was changed.

`run-litmus.sh` was also wrong in a way that could not have worked: it looped
`herd7 -model x86|aarch64|riscv`, but `-model` takes `cav12` or a `.cat`
filename, and a C test cannot be run against an architecture model at all —

```
herd7: bad tag for -model, allowed tag are cav12,<filename>.cat.
```

It now runs the two tiers described above **and checks each verdict against the
expectation the test file itself declares**, failing on a mismatch in either
direction. The old script only noticed a non-zero herd7 exit, which the parse
failures did not produce.

`core/shm_gset_core.c`'s header suggested `nidhugg --c11`; there is no such
flag. Nidhugg's models are `--sc/--tso/--pso/--arm/--power`.

The HM-2 litmus additions, and what each pins:

| Test | Shape | Pins |
|---|---|---|
| `reset-rearm-publish.litmus` | MP, release→acquire | the consumer-liveness re-arm is visible to anyone who observes the new generation. Forbidden. |
| `reset-rearm-publish-RELAXED-control.litmus` | MP, relaxed | Allowed on aarch64/riscv — the shipped release/acquire is load-bearing. |
| `reset-runid-stamp.litmus` | MP, release→acquire | the alternating runId slot is fully written before the generation that selects it. Forbidden. |
| `reset-seal-vs-register.litmus` | **SB (Dekker), seq_cst** | reset and an attaching producer cannot both miss each other. Forbidden. |
| `reset-seal-vs-register-RELAXED-control.litmus` | SB, release/acquire | Allowed on **every** model **including x86** — which is why this pair alone is `seq_cst`. |

The `C` litmus tests encode the exact release→acquire message-passing shape of
every publish pair: slot publish, arena-offset follow, header-magic attach,
shard-link, chain-bump. Each shipped test's `exists` clause must be **Forbidden**
("Never"); the `-RELAXED-control` companion must be **Allowed**, which is what
proves the shipped ordering is load-bearing. Those verdicts are C11 LANGUAGE
verdicts; the per-hardware-model verdicts (x86-TSO, ARMv8, RISC-V) come from the
assembly translations in `litmus/arch/`, because herd7 will not run a C test
against an architecture model. At the hardware level the eleven C tests collapse
to just two shapes — MP with release/acquire (seven of them) and SB with seq_cst
(one) — so `arch/` holds four shapes across three architectures rather than
eleven duplicated translations.

The C11 core (`core/shm_gset_core.c`) is the **same memory orders** the Nim
library uses (`memory_order_release` slot CAS, `seq_cst` arena bump, `acq_rel`
chain-bump, `acquire` reader loads) on a tiny forced-collision table with two
producers — the compilation unit a model checker drives, matching the shipped
algorithm rather than paraphrasing it.

## The four protocol models

`tla/shm_gset.tla` models the **identity** key discipline (`ShmGSetT[IdentityKey]`,
io-mon): the element is its own key, membership only. `tla/shm_gset_reset.tla`
models RECYCLING on top of that — the chain generation, generation-stamped
slots, the producer registry and its seal, and the liveness re-arm (see "The
reset model has teeth" at the end of this file). `tla/shm_gset_pool.tla` models
the HOST-SIDE POOL on top of THAT — the acquire / confirmed-reset / lease /
release / retire lifecycle N in-flight actions drive around `reset` (see "The
pool model has teeth too"). `tla/shm_gset_keyed.tla`
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

### Every model was checked for VACUITY, not just for green

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
- `tla/shm_gset_reset.tla` — model of the RESET / RECYCLING protocol (HM-2):
  the chain generation, generation-stamped slots, the producer registry and the
  quiescence refusal, the reset seal, and the liveness re-arm ordered before the
  commit. Parameterised on three booleans (`QuiescenceCheck`, `Sealed`,
  `RearmFirst`) so each mechanism can be switched OFF and the resulting
  violation observed.
- `tla/shm_gset_reset_MC.{tla,cfg}` — the shipped configuration: two producers
  over a 2-slot table, `MaxGen = 3` (two recycles).
- `tla/shm_gset_reset_probes.tla` — the vacuity + teeth probes below, so they can
  be re-derived rather than taken on faith.
- `tla/shm_gset_pool.tla` — model of the HOST-SIDE RECYCLING POOL lifecycle
  (HM-3): acquire / confirmed-reset / lease / release / retire, driven by N
  in-flight actions. Parameterised on three booleans (`ResetOnAcquire`,
  `ExclusiveIdle`, `RetireOnPermanent`) so each mechanism can be switched OFF
  and the resulting violation observed.
- `tla/shm_gset_pool_MC.{tla,cfg}` — the shipped configuration: two workers,
  two chains, two actions each, `MaxGen = 3`, `BusyBudget = 2`.
- `tla/shm_gset_pool_probes.tla` — its vacuity probes.
- `litmus/*.litmus` — herd7 `C` litmus tests, checked against the C11 LANGUAGE
  models. Wired as `just verify-litmus` (tier 1).
- `litmus/arch/*.litmus` — AArch64 / RISC-V / x86-64 ASSEMBLY translations of the
  same two shapes, checked against `aarch64.cat`, `riscv.cat`, `x86tso.cat`.
  This is the per-architecture tier, and the ARMv8 coverage qemu-user cannot
  give. Wired as `just verify-litmus` (tier 2).
- `litmus/run-litmus.sh` — runs both tiers and CHECKS every verdict against the
  expectation declared in the test file; fails on a mismatch in either direction.
- `core/shm_gset_core.c` — extracted C11 atomics core (+ `build-aarch64-qemu.sh`).
- `core/shm_gset_reset_core.c` — extracted C11 atomics core of the RESET
  protocol, with the `-DRELAXED_SEAL` control. Wired as `just verify-core`
  (native) and `just verify-models` (GenMC, Nidhugg).
- `cdschecker/*.c` + `cdschecker/run-cdschecker.sh` — the publish and handshake
  shapes ported to CDSChecker's replacement atomics/thread API, because
  CDSChecker cannot consume the pthreads cores as they stand. Wired as
  `just verify-cdschecker`.
- `run-rr-chaos.sh` — rr chaos record/replay driver (used by `just test-rr`).
- `../nix/{herdtools7,genmc,nidhugg,cdschecker}.nix` — the four checkers,
  packaged here because nixpkgs does not carry them. `../flake.nix` + the
  committed `../flake.lock` are what make every result above reproducible.

## The reset model has teeth (each mechanism was switched off and re-checked)

A green run proves nothing unless the model can express the failure. Every
mechanism `reset` relies on was disabled in turn, from the SAME module, and TLC
was re-run:

| Configuration | Result |
|---|---|
| shipped (`QuiescenceCheck`, `Sealed`, `RearmFirst` all TRUE) | **green** — 901 distinct states, all 5 invariants and `EventuallyQuiet` hold |
| `QuiescenceCheck = FALSE` | **`NoCrossGenerationLeak` violated** — a producer of the finished action publishes under the new generation |
| `Sealed = FALSE` (quiescence still checked) | **`NoCrossGenerationLeak` violated** — a producer attaches BETWEEN the quiescence check and the commit. This is a real hole the model found in the first draft of the implementation; the seal was added because of it. Counterexample: `CResetCheck` → `PAttach` → `CResetRearm` → `CResetPublish` → `PRead` (observes the new generation) → `PPublish`. |
| `RearmFirst = FALSE` (commit, then re-arm) | **`LivenessArmedUnderCurrentGen` violated** — the new generation is visible while the token still reads gone, so every producer of the next action fast-fails |

And the model was checked for VACUITY the same way the keyed model was, by
asserting the negation of each behaviour of interest and confirming TLC reports
a violation:

```
NoRecycleProbe   == gen < 2                                  -> violated (a reset happens)
NoTwoRecycles    == gen < 3                                  -> violated (twice)
NoStaleSlotProbe == \A i : slotGen[i] = 0 \/ slotGen[i] = gen -> violated (stale slots exist)
NoMarkGoneProbe  == alive = 1                                -> violated (the action ends)
NoPublishProbe   == Visible = {}                             -> violated (elements are published)
```

One probe is deliberately NOT violated in the shipped configuration and that is
the point rather than vacuity:

```
NoStraddle == \A p : pact[p] = 0 \/ pgen[p] = 0 \/ pact[p] = pgen[p]
```

No producer can ever hold an attach across a generation change. It IS violated
as soon as either `QuiescenceCheck` or `Sealed` is switched off, which is what
shows the model can express straddling and that both mechanisms are needed.

## The pool model has teeth too (HM-3)

`tla/shm_gset_pool.tla` models the lifecycle the recycling POOL adds ON TOP of
`reset`. Stating the scope precisely matters, because it would be easy to read
this as a second weak-memory artifact and it is not one:

**The pool adds no new SHARED-MEMORY protocol.** Its only segment operations are
`createSet`, `reset`, `markConsumerGone` and `detach` — every one of them
already modelled by `shm_gset_reset.tla` and already checked under weak memory
by `core/shm_gset_reset_core.c`, `litmus/reset-*.litmus` and GenMC/RC11. No new
atomic, no new ordering, no new access pattern; `verify-core`, `verify-litmus`,
`verify-models` and `verify-cdschecker` are byte-for-byte unchanged by HM-3 and
their results carry over unaltered. What the pool DOES add is a concurrent
LIFECYCLE — acquire, confirmed reset, lease, release, retire, driven by N
in-flight actions inside one process behind a mutex — and that lifecycle has
safety properties no existing artifact states. TLC is the right tool for it
precisely because the lifecycle is mutex-guarded and sequentially consistent.

**And the coverage boundary, stated because it has already cost a regression.**
`shm_gset_pool.tla` models *one process*. There is no second process in it, no
`fork`, and no `destroySetPool` — the shutdown half of the lifecycle is `close`
and `retire` only. So the pool's OWNERSHIP rule ("a pooled chain belongs to the
process that created it; every mutating entry point refuses from any other
process") is **not covered by this model at all, and could not be**. That is not
a hypothetical gap: the round in which the `created` sweep moved into
`destroySetPool` and the `getpid()` guard was not moved with it produced a fork
child that unlinked its parent's live chain, and TLC stayed green throughout,
because there was nothing in the model that could have gone red. The only guards
on that rule are the two Nim fork tests,
`a_fork_child_cannot_touch_the_parents_pooled_chain` (covering `acquire` /
`release` / `close`) and `a_fork_child_cannot_destroy_the_parents_pool`
(covering `destroySetPool`). **If the guard list in `pool.nim` grows a sixth
entry point, the test list has to grow with it — the formal tier will not
notice.** Adding a second process to this model would mean modelling COW address
spaces and the file namespace, which is a different artifact from the one this
module is; the decision was to name the boundary rather than blur it.

One state the pool genuinely introduces is a chain that has been marked GONE and
is sitting idle, dirty, for an unbounded time before its next reset. That is not
new to the model: `shm_gset_reset.tla` already lets a producer attach at any
unsealed moment INCLUDING after the consumer has marked itself gone, so both the
"blocks the reset" and the "fast-fails on the liveness token" paths were already
explored rather than assumed away.

| Configuration | Result |
|---|---|
| shipped (`ResetOnAcquire`, `ExclusiveIdle`, `RetireOnPermanent` all TRUE) | **green** — 7,444 distinct states, depth 15, all 8 invariants and `EventuallyAllServed` hold |
| `ResetOnAcquire = FALSE` (hand out the idle chain as it is) | **`NeverUnresetHandout` violated** — a worker holds a chain whose generation never moved past the one the pool was holding, i.e. the previous action's evidence |
| `ExclusiveIdle = FALSE` (a leased chain stays in the idle set) | **`NoSharedChain` violated** — two in-flight actions hold one chain. With `NoSharedChain` removed from the config, **`LeaseGenStable`** is violated as well: the second acquire RECYCLES the chain under the first holder |
| `RetireOnPermanent = FALSE` (retry an untracked / exhausted chain like a busy one) | **`NoPermanentlyIdleChain` violated** — a chain that can never be recycled again sits in the idle set forever, warm, mapped and useless, looking merely busy |

And the vacuity probes, all confirmed VIOLATED (i.e. the behaviour really is
reached) against the shipped configuration:

```
NoConcurrentLeasesProbe -> violated  (two leases ARE in flight at once, so
                                      NoSharedChain is not vacuously true)
NoRecycleProbe          -> violated  (a chain really is recycled)
NoTwoRecyclesProbe      -> violated  (...more than once)
NoRetireProbe           -> violated  (a chain really is retired)
NoBusyRetireProbe       -> violated  (the BUSY budget really is exhausted)
NoPermanentRefusalProbe -> violated  (a PERMANENT refusal really is seen, so
                                      NoPermanentlyIdleChain is not vacuous)
NoReleaseProbe          -> violated  (actions really end and hand chains back)
```

Two abstractions in the pool model are deliberate and are named in the module
header rather than left to be discovered: the idle list is a SET, not a queue
(which chain an acquire picks is irrelevant to every invariant; the FIFO
rotation in the implementation only decides WHEN a refused chain is retried,
which is quality of service, not safety), and `maxIdle` is omitted (it only ever
retires MORE chains, which cannot falsify any invariant here). A third is worth
flagging because it looks like a bound and is not: a RETIRED chain's slot
returns to `absent`, because a retired chain's files are unlinked and its
identity is gone, so `Chains` bounds CONCURRENT chains rather than chains over
time — which matches the implementation, where nothing bounds how many chains a
pool creates in its life. Without that, TLC reports a spurious liveness failure
the moment every slot has been retired once; that is an artifact of the bound,
not a property of the pool, and it was observed before being fixed.

## Which artifact covers which HALF of the Dekker handshake

The seal handshake has two halves, and they are not covered by the same thing.
Stating this precisely matters, because one of them is UNREACHABLE from the Nim
suite and a vague claim would paper that over.

| Half | What removing it breaks | Covered by |
|---|---|---|
| attach reads the seal BEFORE claiming a registry entry | a producer attaches while a reset is visibly in progress | `tests/test_shm_gset_reset.nim` → *a producer attaching DURING a reset cannot slip into the new generation*. Deleting the seal store reddens it on `sealChildCode == 20`. |
| attach RE-READS the seal AFTER claiming its entry | a producer whose first read beat the seal store, and whose registration lost to reset's registry scan, slips into the new generation | the C11 core — natively on x86-64 (below), **and now exhaustively under GenMC/RC11**, which is the `m6` gap and the first coverage of this half that is not a probability |

The Nim test drives the window with a schedule hook at
`spBeforeGenerationPublish`, by which point the seal is already stored, so the
attempted attach is stopped by the FIRST read and the test cannot distinguish the
second. Removing only the re-read therefore reddens NOTHING in the Nim suite;
that is a real limit of a deterministic seam, reported rather than hidden.

The second half is covered by `core/shm_gset_reset_core.c`, whose `attach()`
performs exactly `CAS the registry entry, then load the seal`. Three independent
demonstrations now: a stateless model checker over all interleavings AND all
C11 reorderings (`just verify-models`, whose RELAXED_SEAL run reports
`Error: Safety violation!` with the offending execution graph — see the `m6`
section above), plus these two on real x86-64:

```
# ORDERING of the second half is load-bearing (this is `just verify-core`):
cc -std=c11 -O2 -pthread -DSTANDALONE -DNITER=100000 -DRELAXED_SEAL \
   core/shm_gset_reset_core.c -o /tmp/relaxed && /tmp/relaxed
#   -> nonzero straddles + cross-generation leaks, every run

# EXISTENCE of the second half is load-bearing (the analogue of deleting only
# the post-register re-read from attachSetT), with the shipped seq_cst orders
# otherwise intact:
sed 's|if (atomic_load_explicit(&seal, SEAL_LOAD) != 0) {|if (0) {|' \
   core/shm_gset_reset_core.c > /tmp/nosecond.c
cc -std=c11 -O2 -pthread -DSTANDALONE -DNITER=100000 /tmp/nosecond.c -o /tmp/nosecond
/tmp/nosecond
#   -> ABORTS on the cross-generation oracle (arena[ri].gen == gen), 3 runs of 3
```
