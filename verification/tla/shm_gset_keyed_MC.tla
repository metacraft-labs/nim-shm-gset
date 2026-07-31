---------------------------- MODULE shm_gset_keyed_MC ----------------------------
(* Finite instance of `shm_gset_keyed` for TLC — the KEYED discipline under      *)
(* concurrent producers, tombstones and growth (no flatten, no reader; those are *)
(* checked by `shm_gset_keyed_flat_MC`, which needs a longer chain and would     *)
(* otherwise multiply this state space).                                        *)
(*                                                                              *)
(* Shape: TWO primary keys that SHARE a home slot (Home[ka] = Home[kb] = 0), so  *)
(* their probe runs interleave in one cluster and every enumeration has to       *)
(* filter foreign elements — the case §6.3 calls out. Key `ka` carries two       *)
(* identities, one of which is put, evicted and resurrected, so the generation   *)
(* protocol is exercised end to end. Each (key, id) pair belongs to exactly ONE  *)
(* producer, which serialises the operations on it and makes                     *)
(* EvictionEffective / PutEffective meaningful; the producers still race each    *)
(* other for slots in the shared run.                                           *)
EXTENDS shm_gset_keyed

CONSTANTS ka, kb, i1, i2, p1, p2

KeysDef      == {ka, kb}
IdsDef       == {i1, i2}
ProducersDef == {p1, p2}
HomeDef      == (ka :> 0) @@ (kb :> 0)

WorkDef ==
    (p1 :> << [op |-> "put",   key |-> ka, id |-> i1],
              [op |-> "evict", key |-> ka, id |-> i1],
              [op |-> "put",   key |-> ka, id |-> i1] >>)
 @@ (p2 :> << [op |-> "put",   key |-> kb, id |-> i1],
              [op |-> "put",   key |-> ka, id |-> i2] >>)
================================================================================
