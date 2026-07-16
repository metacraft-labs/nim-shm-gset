------------------------------- MODULE shm_set_MC -------------------------------
(* Finite instance of `shm_set` for TLC. Three distinct elements over a       *)
(* 2-slot shard force a real grow-by-sharding (shard1 fills, the 3rd distinct *)
(* element opens shard2); `a` and `c` share home slot 0 to exercise linear    *)
(* probing and the slot-claim race; the two producers share element `b` to    *)
(* exercise idempotent dedup and cross-shard duplication.                     *)
EXTENDS shm_set

CONSTANTS a, b, c, p1, p2

HomeDef      == (a :> 0) @@ (b :> 1) @@ (c :> 0)
WorkDef      == (p1 :> <<a, b>>) @@ (p2 :> <<b, c>>)
ProducersDef == {p1, p2}
================================================================================
