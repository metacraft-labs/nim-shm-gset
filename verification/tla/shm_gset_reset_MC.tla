---------------------------- MODULE shm_gset_reset_MC ----------------------------
(* Finite instance of `shm_gset_reset` for TLC: the SHIPPED configuration —   *)
(* quiescence checked, the check sealed, the liveness token re-armed before   *)
(* the generation is published.                                              *)
(*                                                                           *)
(* Two producers over a 2-slot table, with `MaxGen = 3` so the chain is       *)
(* recycled twice and a producer can straddle a reset. `p1` and `p2` insert   *)
(* DISTINCT elements that share home slot 0, so both the slot-claim race and  *)
(* the stale-slot reuse are exercised.                                       *)
EXTENDS shm_gset_reset

CONSTANTS p1, p2, x, y, none

ElemOfDef    == (p1 :> x) @@ (p2 :> y)
HomeOfDef    == (x :> 0) @@ (y :> 0)
ProducersDef == {p1, p2}
================================================================================
