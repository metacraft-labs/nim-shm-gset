-------------------------- MODULE shm_gset_keyed_flat_MC --------------------------
(* Finite instance of `shm_gset_keyed` for TLC exercising FLATTENING and         *)
(* RETIREMENT (spec §6.7) against a CONCURRENT READER.                           *)
(*                                                                              *)
(* One producer, so this configuration spends its state space on the             *)
(* flattener/reader interleaving rather than on producer-vs-producer slot races  *)
(* (those are `shm_gset_keyed_MC`'s job). Its five operations produce five       *)
(* distinct elements — a record, a foreign-key record, a second identity, a      *)
(* tombstone and a resurrection — which at `Cap = 2` fills shards 1 and 2 and     *)
(* opens shard 3, so shard 2 (strictly between the never-retired anchor and the  *)
(* newest shard) genuinely becomes flattenable WHILE the producer is still       *)
(* writing.                                                                      *)
(*                                                                              *)
(* Both primary keys share a home slot, so a flattened element is copied back    *)
(* into a run that already interleaves foreign keys, and the destination shard   *)
(* runs out of room mid-flatten — exercising the grow-during-flatten path.       *)
(*                                                                              *)
(* That the flatten actually HAPPENS in this configuration is not assumed: see   *)
(* `verification/README.md` for the reachability check (assert `~drained[s]` as  *)
(* an invariant and confirm TLC reports it violated).                            *)
EXTENDS shm_gset_keyed

CONSTANTS ka, kb, i1, i2, p1

KeysDef      == {ka, kb}
IdsDef       == {i1, i2}
ProducersDef == {p1}
HomeDef      == (ka :> 0) @@ (kb :> 0)

WorkDef ==
    (p1 :> << [op |-> "put",   key |-> ka, id |-> i1],
              [op |-> "put",   key |-> kb, id |-> i1],
              [op |-> "put",   key |-> ka, id |-> i2],
              [op |-> "evict", key |-> ka, id |-> i1],
              [op |-> "put",   key |-> ka, id |-> i1] >>)
================================================================================
