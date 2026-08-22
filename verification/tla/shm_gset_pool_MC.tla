---------------------------- MODULE shm_gset_pool_MC ----------------------------
(* Finite instance of `shm_gset_pool` for TLC: the SHIPPED configuration —    *)
(* acquire resets before handing out, a leased chain leaves the idle set, and *)
(* a permanently-unrecyclable chain is retired rather than retried.           *)
(*                                                                           *)
(* TWO workers so the actions really are in flight together, TWO chains so    *)
(* the pool can be forced to create a replacement after a retirement, and     *)
(* TWO rounds each so a chain is genuinely RECYCLED rather than merely used   *)
(* once — one round could not observe the property this milestone is about.   *)
(* `MaxGen = 3` puts generation exhaustion inside the explored space and      *)
(* `BusyBudget = 2` puts budget-exhausted retirement inside it too.           *)
EXTENDS shm_gset_pool

CONSTANTS ca, cb, nochain

ChainsDef  == {ca, cb}
WorkersDef == {"wa", "wb"}
================================================================================
