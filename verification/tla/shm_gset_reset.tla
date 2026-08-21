----------------------------- MODULE shm_gset_reset -----------------------------
(***************************************************************************)
(* TLA+ model of the `nim-shm-gset` RESET / RECYCLING protocol (HM-2), the   *)
(* §4.5(a) obligation for a lock-free, multi-process, crash-exposed          *)
(* operation.                                                               *)
(*                                                                          *)
(* WHAT THIS MODELS — the recycling protocol under interleaving semantics:  *)
(*   * a chain generation, authoritative in shard0, published by ONE store; *)
(*   * generation-stamped slots: a slot is EMPTY unless its stamp equals the*)
(*     current generation, so recycling is that one store and nothing else; *)
(*   * a producer registry (attach/detach) and the QUIESCENCE refusal built *)
(*     on it;                                                               *)
(*   * the RESET SEAL: a store-buffer handshake between "seal then scan the *)
(*     registry" (reset) and "claim a registry entry then read the seal"    *)
(*     (attach), which is what closes the window between the quiescence     *)
(*     check and the commit;                                                *)
(*   * the consumer-liveness token, marked gone at the end of an action and *)
(*     RE-ARMED by reset BEFORE the generation becomes visible;             *)
(*   * a producer reading the generation and the liveness token, then       *)
(*     publishing its element into a slot with the stamp IT read.           *)
(*                                                                          *)
(* THE ORACLE. `intended[g]` is the set of elements belonging to the action *)
(* that owned generation `g` — fixed when a producer ATTACHES, because a    *)
(* producer belongs to the action that launched it, not to whatever         *)
(* generation it happens to observe later. That distinction is the entire   *)
(* point: cross-attribution is exactly "an element of intended[g] visible   *)
(* under generation h /= g".                                                *)
(*                                                                          *)
(* SCOPE / WHAT THIS DOES NOT MODEL — WEAK MEMORY. TLC explores             *)
(* SEQUENTIALLY CONSISTENT interleavings. The sufficiency of the specific   *)
(* release/acquire and seq_cst annotations is the herd7 / GenMC job         *)
(* (../litmus/reset-*.litmus, ../core/shm_gset_core.c). What THIS proves is *)
(* that the protocol is correct GIVEN correct ordering.                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Producers,     \* set of producer process ids
    ElemOf,        \* [Producer -> Element] : the element each producer inserts
    Cap,           \* slots per shard
    HomeOf,        \* [Element -> 0..Cap-1] : home slot
    MaxGen,        \* bound on the generation counter
    NoElem,        \* a value outside Elements, standing for an empty slot
    QuiescenceCheck, \* TRUE  == reset refuses while producers are attached
    Sealed,        \* TRUE  == reset seals the attach window around the check
    RearmFirst     \* TRUE  == re-arm the liveness token BEFORE publishing gen

Elements == { ElemOf[p] : p \in Producers }
Slots == 0..(Cap-1)

ASSUME Cap \in Nat /\ Cap >= 1
ASSUME NoElem \notin Elements
ASSUME MaxGen \in Nat /\ MaxGen >= 2

VARIABLES
    gen,        \* shard0's generation counter (the commit point)
    alive,      \* consumer-liveness token, 0 or 1
    goneAt,     \* the generation at which the consumer last marked itself gone
    seal,       \* reset-in-progress seal, 0 or 1
    slotGen,    \* [Slots -> Nat]      : each slot's generation stamp
    slotVal,    \* [Slots -> Element \cup {NoElem}]
    pstate,     \* [Producers -> {"off","attached","read","done"}]
    pact,       \* [Producers -> Nat] : the generation this producer BELONGS to
    pgen,       \* [Producers -> Nat] : the generation this producer READ
    palive,     \* [Producers -> {0,1}] : the liveness token it read
    reg,        \* [Producers -> BOOLEAN] : registry entry claimed
    cstate,     \* consumer: "running" | "gone" | "checked" | "stamped"
    intended,   \* [1..MaxGen -> SUBSET Elements] : the oracle
    lost        \* elements a producer had to abandon because the consumer read
                \* as gone under a generation that was already recycled

vars == << gen, alive, goneAt, seal, slotGen, slotVal, pstate, pact, pgen,
           palive, reg, cstate, intended, lost >>

Init ==
    /\ gen = 1
    /\ alive = 1
    /\ goneAt = 0
    /\ seal = 0
    /\ slotGen = [i \in Slots |-> 0]
    /\ slotVal = [i \in Slots |-> NoElem]
    /\ pstate = [p \in Producers |-> "off"]
    /\ pact = [p \in Producers |-> 0]
    /\ pgen = [p \in Producers |-> 0]
    /\ palive = [p \in Producers |-> 0]
    /\ reg = [p \in Producers |-> FALSE]
    /\ cstate = "running"
    /\ intended = [g \in 1..MaxGen |-> {}]
    /\ lost = {}

(*************************************************************************)
(* PRODUCER                                                              *)
(*                                                                       *)
(* Attach is modelled as the code performs it: claim the registry entry, *)
(* THEN read the seal, and back out if it is set. With `Sealed = FALSE`  *)
(* the seal read is skipped, which is the pre-seal implementation.       *)
(*************************************************************************)
PAttach(p) ==
    /\ pstate[p] = "off"
    /\ ~(Sealed /\ seal = 1)                 \* claimed, then saw the seal
    /\ pstate' = [pstate EXCEPT ![p] = "attached"]
    /\ pact' = [pact EXCEPT ![p] = gen]      \* it belongs to THIS action
    /\ reg' = [reg EXCEPT ![p] = TRUE]
    /\ intended' = [intended EXCEPT ![gen] = @ \cup {ElemOf[p]}]
    /\ UNCHANGED << gen, alive, goneAt, seal, slotGen, slotVal, pgen, palive,
                    cstate, lost >>

\* `emit`: read the generation (acquire), then the liveness token.
PRead(p) ==
    /\ pstate[p] = "attached"
    /\ pgen' = [pgen EXCEPT ![p] = gen]
    /\ palive' = [palive EXCEPT ![p] = alive]
    /\ pstate' = [pstate EXCEPT ![p] = "read"]
    /\ UNCHANGED << gen, alive, goneAt, seal, slotGen, slotVal, pact, reg,
                    cstate, intended, lost >>

\* The consumer read as gone: fast-fail, publish nothing.
PAbort(p) ==
    /\ pstate[p] = "read"
    /\ palive[p] = 0
    /\ pstate' = [pstate EXCEPT ![p] = "done"]
    /\ lost' = IF pgen[p] > goneAt THEN lost \cup {ElemOf[p]} ELSE lost
    /\ UNCHANGED << gen, alive, goneAt, seal, slotGen, slotVal, pact, pgen,
                    palive, reg, cstate, intended >>

\* Claim any slot that is not LIVE under the generation this producer read,
\* stamping it with that generation. Linear probing is abstracted to "some
\* claimable slot": which slot is claimed is irrelevant to every property
\* below, and probe-run completeness is already proven by shm_gset.tla.
PPublish(p) ==
    /\ pstate[p] = "read"
    /\ palive[p] = 1
    /\ \E i \in Slots :
         /\ slotGen[i] # pgen[p]
         /\ slotGen' = [slotGen EXCEPT ![i] = pgen[p]]
         /\ slotVal' = [slotVal EXCEPT ![i] = ElemOf[p]]
    /\ pstate' = [pstate EXCEPT ![p] = "done"]
    /\ UNCHANGED << gen, alive, goneAt, seal, pact, pgen, palive, reg, cstate,
                    intended, lost >>

PDetach(p) ==
    /\ pstate[p] = "done"
    /\ reg[p]
    /\ reg' = [reg EXCEPT ![p] = FALSE]
    /\ UNCHANGED << gen, alive, goneAt, seal, slotGen, slotVal, pstate, pact,
                    pgen, palive, cstate, intended, lost >>

(*************************************************************************)
(* CONSUMER                                                              *)
(*************************************************************************)
CMarkGone ==
    /\ cstate = "running"
    /\ alive' = 0
    /\ goneAt' = gen
    /\ cstate' = "gone"
    /\ UNCHANGED << gen, seal, slotGen, slotVal, pstate, pact, pgen, palive,
                    reg, intended, lost >>

\* reset step 0: take the seal, then scan the registry. A busy chain drops the
\* seal again and stays in "gone" (the caller sees rsBusyProducers).
CResetCheck ==
    /\ cstate = "gone"
    /\ gen < MaxGen
    /\ (~QuiescenceCheck \/ \A p \in Producers : ~reg[p])
    /\ seal' = IF Sealed THEN 1 ELSE 0
    /\ cstate' = "checked"
    /\ UNCHANGED << gen, alive, goneAt, slotGen, slotVal, pstate, pact, pgen,
                    palive, reg, intended, lost >>

\* reset steps 1 and 2, as two SEPARATE steps so their ORDER is observable.
\* Shipped (`RearmFirst = TRUE`): re-arm the liveness token, then commit the
\* generation. Swapped (`RearmFirst = FALSE`): commit first, re-arm after —
\* which leaves a state in which the new generation is visible while the token
\* still reads gone, and every producer of the next action fast-fails there.
CResetRearm ==
    /\ cstate = "checked"
    /\ IF RearmFirst
         THEN /\ alive' = 1
              /\ UNCHANGED gen
         ELSE /\ gen' = gen + 1
              /\ UNCHANGED alive
    /\ cstate' = "stamped"
    /\ UNCHANGED << goneAt, seal, slotGen, slotVal, pstate, pact, pgen,
                    palive, reg, intended, lost >>

CResetPublish ==
    /\ cstate = "stamped"
    /\ IF RearmFirst
         THEN /\ gen' = gen + 1
              /\ UNCHANGED alive
         ELSE /\ alive' = 1
              /\ UNCHANGED gen
    /\ seal' = 0
    /\ cstate' = "running"
    /\ UNCHANGED << goneAt, slotGen, slotVal, pstate, pact, pgen, palive, reg,
                    intended, lost >>

Next ==
    \/ \E p \in Producers :
         PAttach(p) \/ PRead(p) \/ PAbort(p) \/ PPublish(p) \/ PDetach(p)
    \/ CMarkGone \/ CResetCheck \/ CResetRearm \/ CResetPublish

PSteps(p) == PAttach(p) \/ PRead(p) \/ PAbort(p) \/ PPublish(p) \/ PDetach(p)
CSteps == CMarkGone \/ CResetCheck \/ CResetRearm \/ CResetPublish

\* Per-process weak fairness: every producer and the consumer eventually take a
\* step that is continuously enabled. Fairness on `Next` as a whole would not do
\* — it permits one producer to be starved forever while another keeps `Next`
\* enabled, and the liveness property below is about EVERY producer finishing.
Spec == Init /\ [][Next]_vars
             /\ (\A p \in Producers : WF_vars(PSteps(p)))
             /\ WF_vars(CSteps)

(*************************************************************************)
(* INVARIANTS                                                            *)
(*************************************************************************)
TypeOK ==
    /\ gen \in 1..MaxGen
    /\ alive \in {0, 1}
    /\ seal \in {0, 1}
    /\ slotGen \in [Slots -> 0..MaxGen]
    /\ slotVal \in [Slots -> Elements \cup {NoElem}]
    /\ cstate \in {"running", "gone", "checked", "stamped"}

\* What a reader observes right now: the elements in slots stamped with the
\* CURRENT generation. Everything else is unreachable by construction.
Visible == { slotVal[i] : i \in {j \in Slots : slotGen[j] = gen} }

\* SAFETY 1 — NO CROSS-GENERATION LEAKAGE.
\* Nothing an earlier action's producer inserted is ever visible under a later
\* generation. This is the milestone's headline property and the cardinal sin
\* it prevents: one action's dependencies attributed to another.
NoCrossGenerationLeak ==
    \A e \in Visible : e \in intended[gen]

\* SAFETY 2 — NOTHING INSERTED AFTER RESET N IS LOST.
\* Every producer that belongs to the current generation and has finished
\* publishing is visible under it. (A producer that belongs to an OLDER
\* generation is deliberately excluded: its evidence has already been read.)
NoLossAfterReset ==
    \A p \in Producers :
        (pstate[p] = "done" /\ pact[p] = gen /\ palive[p] = 1)
            => ElemOf[p] \in Visible

\* SAFETY 3 — THE LIVENESS TOKEN IS NEVER GONE UNDER THE CURRENT GENERATION.
\* Once a generation newer than the one the consumer abandoned is visible, the
\* token must read as live: otherwise every producer of the next action
\* fast-fails with emConsumerGone, silently and with nobody watching.
LivenessArmedUnderCurrentGen ==
    (gen > goneAt) => (alive = 1)

\* SAFETY 4 — the direct consequence of 3: no producer ever had to abandon its
\* element because the token read gone under a generation already recycled.
NoProducerAbandonedUnderCurrentGen == lost = {}

\* SAFETY 5 — a slot's stamp never exceeds the published generation, which is
\* what makes "newer" a total order and stops a stale slot from ever reading as
\* live again (the wraparound hazard `reset` refuses rather than risks).
StampsDominatedByGeneration ==
    \A i \in Slots : slotGen[i] <= gen

\* LIVENESS — the chain does eventually get recycled and the producers finish.
EventuallyQuiet == <>[](\A p \in Producers : pstate[p] = "done")
================================================================================
