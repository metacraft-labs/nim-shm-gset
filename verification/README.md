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

The boundary is exactly `verify-*`. `just test`, `just soak`, `just bench` and
the `test-sanitizers` / `test-valgrind` / `test-rr` targets deliberately keep
using the AMBIENT workspace toolchain — that is what a developer edits against
all day, and io-mon consumes this repo as a plain source path compiled by
io-mon's own Nim. The rows below that say "(dev shell)" mean that ambient
toolchain, not the flake. `nix develop . -c just test` also works and gives the
same 85 `[OK]` / 0 `[FAILED]`; it is simply not forced.

```
just verify            # the whole tier
just verify-tla        # TLC, 4 models
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
| Valgrind DRD + helgrind | `valgrind` (dev shell) | `just test-valgrind` | **RAN — 0 errors** (both tools) |
| rr chaos record + replay | `rr` (dev shell) | `just test-rr` | **RAN — green.** Oracle held across 5 chaos schedules + 1 deterministic replay |
| Longer bounded soak | Nim (dev shell) | `just soak <secs>` | **RAN — green** (60 s: distinct=7200, growthFailures=0) |
| C11 atomics core, native | `gcc` (dev shell) | `core/` `-DSTANDALONE` | **RAN — green** (200000 slot-claim races) + TSAN clean |
| C11 atomics core, aarch64 | cross-gcc + `qemu-aarch64` | `core/build-aarch64-qemu.sh` | **RAN — green, FUNCTIONAL ONLY** (see caveat) |
| **Reset/recycling protocol (HM-2)** | TLA+ / TLC | `just verify-tla` | **RAN — green.** 901 distinct states, depth 18, 5 safety invariants + 1 temporal property. `just verify-tla` is 4/4 green end to end (750 / 38 151 / 51 375 / 901 distinct states), exit 0 |
| **Reset/recycling C11 core, native** | `gcc` | `just verify-core` | **RAN — green** (100 000 barrier-synchronised reset-vs-insert races) + TSAN clean |
| **Reset core, `-DRELAXED_SEAL` control** | `gcc` | `just verify-core` | **RAN — FAILS AS INTENDED** on x86-64: **1–43** straddles and **52–158** cross-generation leaks per 100 000 runs, measured over 10 runs on one machine. That range is an OBSERVATION, not a specification, and it has now been over-tightened twice (13–27 / 86–166, then 9–26 / 55–109) before being blown through in both directions. The claim that matters is: NONZERO on the control, ZERO on the shipped build, 10/10 and 4/4. Read the caveat below about how thin the low end is |
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
  **But the native control is PROBABILISTIC, and thinner than it looks.** One of
  the ten measured runs found a single straddle in 100 000 — 1, not 9 — so a
  quieter machine, a different core count, or a different scheduler could
  plausibly return zero and make the control look like it had passed. Treat a
  zero from `just verify-core`'s control as "inconclusive, re-run under load",
  never as "the ordering does not matter". The claim does NOT rest on this:
  `just verify-models` demonstrates the same hazard EXHAUSTIVELY under GenMC/
  RC11, where "reachable" is decided rather than sampled, and that is the leg
  that makes the result independent of this machine's timing.
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

## The three protocol models

`tla/shm_gset.tla` models the **identity** key discipline (`ShmGSetT[IdentityKey]`,
io-mon): the element is its own key, membership only. `tla/shm_gset_reset.tla`
models RECYCLING on top of that — the chain generation, generation-stamped
slots, the producer registry and its seal, and the liveness re-arm (see "The
reset model has teeth" at the end of this file). `tla/shm_gset_keyed.tla`
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
