------------------------ MODULE shm_gset_reset_probes ------------------------
(* VACUITY + TEETH probes for `shm_gset_reset`. Not part of the shipped        *)
(* configuration: this module exists so the reviewer can re-derive, rather     *)
(* than take on faith, that the green run in `shm_gset_reset_MC` is not green  *)
(* because the model never reaches the interesting states.                     *)
(*                                                                            *)
(* Each probe below asserts the NEGATION of a behaviour the model must reach.  *)
(* Add one to the INVARIANTS section of a copy of `shm_gset_reset_MC.cfg`,     *)
(* point TLC at THIS module instead, and confirm TLC reports it VIOLATED:      *)
(*                                                                            *)
(*   sed 's/^INVARIANTS/INVARIANTS\n    NoStaleSlotProbe/' \                   *)
(*     shm_gset_reset_MC.cfg > /tmp/probe.cfg                                  *)
(*   tlc -workers 4 -config /tmp/probe.cfg shm_gset_reset_probes.tla           *)
(*                                                                            *)
(* Results at the time of writing (all against the SHIPPED configuration):     *)
(*                                                                            *)
(*   NoRecycleProbe    VIOLATED   a reset really happens                       *)
(*   NoTwoRecycles     VIOLATED   ...twice, so a chain is reused repeatedly    *)
(*   NoStaleSlotProbe  VIOLATED   stale slots really exist under a new gen     *)
(*   NoMarkGoneProbe   VIOLATED   the action really ends                       *)
(*   NoPublishProbe    VIOLATED   elements are really published                *)
(*   NoStraddle        HOLDS      <- NOT vacuity: this is the property. No     *)
(*                                producer can hold an attach across a         *)
(*                                generation change. It becomes VIOLATED the   *)
(*                                moment `QuiescenceCheck` or `Sealed` is set  *)
(*                                FALSE, which is what proves the model CAN    *)
(*                                express straddling and that both mechanisms  *)
(*                                are load-bearing.                            *)
EXTENDS shm_gset_reset

CONSTANTS p1, p2, x, y, none

ElemOfDef    == (p1 :> x) @@ (p2 :> y)
HomeOfDef    == (x :> 0) @@ (y :> 0)
ProducersDef == {p1, p2}

NoRecycleProbe   == gen < 2
NoTwoRecycles    == gen < 3
NoStaleSlotProbe == \A i \in Slots : slotGen[i] = 0 \/ slotGen[i] = gen
NoMarkGoneProbe  == alive = 1
NoPublishProbe   == Visible = {}

\* THE property, not a probe: `pact[p]` is the generation the producer belongs
\* to and `pgen[p]` the one it read. They can only differ if a reset committed
\* while this producer held an attach.
NoStraddle ==
    \A p \in Producers :
        pact[p] = 0 \/ pgen[p] = 0 \/ pact[p] = pgen[p]
==============================================================================
