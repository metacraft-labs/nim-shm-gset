----------------------------- MODULE shm_gset_keyed -----------------------------
(***************************************************************************)
(* TLA+/PlusCal model of `nim-shm-gset` under a NON-IDENTITY key discipline: *)
(* the primary hash is computed over the PRIMARY KEY alone, several elements *)
(* share one key (a multimap with no stored chain), and retirement is by     *)
(* TOMBSTONE — the discipline reprobuild's action-cache index needs           *)
(* (reprobuild-specs/Action-Cache-Per-Edge-Store.md §6.1–6.7).               *)
(*                                                                          *)
(* `shm_gset.tla` models the identity discipline: key = element, membership  *)
(* only. Everything it proves still holds and is still checked there. THIS   *)
(* module adds the properties that discipline cannot express:                *)
(*                                                                          *)
(*   RunEnumerationExact        the walk from a key's home slot to the first *)
(*                              empty slot yields EXACTLY that key's         *)
(*                              elements (filtering on the stored key), in   *)
(*                              every shard — no stored chain, no early stop *)
(*   RunIntegrityAcrossShards   a key's elements may be split across shards  *)
(*                              by growth; the union of the per-shard walks  *)
(*                              is still exactly the key's element set       *)
(*   EnumerationDecidesLikeUnion  liveness computed from the probe-run walk  *)
(*                              equals liveness computed omnisciently from   *)
(*                              every published element                      *)
(*   EvictionEffective /        the generation protocol actually retires and *)
(*   PutEffective               actually resurrects, in EVERY interleaving   *)
(*                              of records and tombstones, across shards     *)
(*   GenerationInvariant        every stamped generation <= the global u64   *)
(*                              counter in shard0 (what makes "newer" a      *)
(*                              total order over the whole chain)            *)
(*   FlattenDrainsOnlyCopied    a shard is marked drained only in a state    *)
(*                              where every element it holds is also present *)
(*                              in a live shard                             *)
(*   ObservabilityMonotone      nothing observable before a flatten becomes  *)
(*                              unobservable after it                        *)
(*   ReaderCompleteUnderFlatten a reader walking the chain OLDEST-FIRST,     *)
(*                              concurrently with copy-forward/drain/retire, *)
(*                              never misses an element that was observable  *)
(*                              when its walk began                          *)
(*                                                                          *)
(* SCOPE — as in `shm_gset.tla`, TLC explores SEQUENTIALLY CONSISTENT         *)
(* interleavings; weak-memory sufficiency is the herd7/GenMC job in          *)
(* ../litmus and ../core. Two further abstractions are deliberate and are    *)
(* stated here rather than buried:                                          *)
(*   (1) a producer's DECIDE step (scan the run, compute the generation to   *)
(*       stamp) is atomic; its INSERT (probe + claim, and growth) is         *)
(*       step-wise, because that is where the CAS race lives. A stale        *)
(*       decision is still modelled: other processes run between DECIDE and  *)
(*       the claim.                                                          *)
(*   (2) the flattener copies one element per step and the reader reads one  *)
(*       SHARD per step. The reader property under test is about the ORDER   *)
(*       shards are visited in, so shard granularity is the right one; a     *)
(*       slot-at-a-time reader multiplies the state space without changing   *)
(*       what the property says.                                            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Producers,       \* set of producer process ids
    Keys,            \* set of PRIMARY keys (the action cache's weak fingerprints)
    Ids,             \* set of key identities within a primary key (strong fps)
    Cap,             \* slots per shard, power of two
    MaxShards,       \* bound on chain length
    MaxGen,          \* bound on the global generation counter
    Empty,           \* the distinguished EMPTY-SLOT marker (a model value)
    Home,            \* [Keys -> 0..Cap-1] : THE KEY ALONE picks the home slot
    Work,            \* [Producer -> Seq([op: {"put","evict"}, key: Keys, id: Ids])]
    FlattenEnabled,  \* run the flattener process?
    ReaderEnabled    \* run the concurrent reader process?

Shards == 1..MaxShards
NumProducers == Cardinality(Producers)

ASSUME Cap \in Nat /\ Cap >= 1
ASSUME MaxShards \in Nat /\ MaxShards >= 1
ASSUME Home \in [Keys -> 0..(Cap-1)]

MaxNum(a, b) == IF a > b THEN a ELSE b
MaxOfSet(S)  == CHOOSE x \in S : \A y \in S : y <= x

(* --algorithm shmgsetkeyed {
  variables
    slot     = [s \in Shards |-> [i \in 0..(Cap-1) |-> Empty]];
    occ      = [s \in Shards |-> 0];
    exists   = [s \in Shards |-> (s = 1)];
    drained  = [s \in Shards |-> FALSE];
    chain    = 1;
    gcount   = 0;                       \* the GLOBAL generation counter (shard0)
    lastOp   = [k \in Keys |-> [i \in Ids |-> "none"]];
    committed = {};
    finished = 0;
    saturated = FALSE;
    rdone    = FALSE;
    rstart   = {};
    rseen    = {};

  define {
    LiveShards  == { s \in Shards : exists[s] /\ ~drained[s] }
    PublishedIn(s) == { slot[s][i] : i \in { j \in 0..(Cap-1) : slot[s][j] # Empty } }
    AllPublished == UNION { PublishedIn(s) : s \in LiveShards }

    \* --- the probe run: home slot -> first empty slot -----------------------
    FirstEmptyFrom(s, h) ==
        IF \E j \in 0..(Cap-1) : slot[s][(h + j) % Cap] = Empty
        THEN CHOOSE j \in 0..(Cap-1) :
                /\ slot[s][(h + j) % Cap] = Empty
                /\ \A m \in 0..(j-1) : slot[s][(h + m) % Cap] # Empty
        ELSE Cap
    RunFrom(s, h) == { slot[s][(h + j) % Cap] :
                         j \in 0..(FirstEmptyFrom(s, h) - 1) }

    \* What an enumeration of key `k` yields: the walk from Home[k] in every live
    \* shard, FILTERED on the stored key (a foreign key in the run costs one
    \* comparison). This is the whole read path — there is no chain to follow.
    RunOfKey(k) == UNION { { e \in RunFrom(s, Home[k]) : e.key = k }
                             : s \in LiveShards }
    ElemsOfKey(k) == { e \in AllPublished : e.key = k }

    \* --- liveness (spec §6.5), by the two routes ---------------------------
    GensOf(S, k, i, t) == { e.gen : e \in { x \in S : x.key = k /\ x.id = i
                                                      /\ x.tomb = t } }
    LiveIn(S, k, i) ==
        /\ GensOf(S, k, i, FALSE) # {}
        /\ \A g \in GensOf(S, k, i, TRUE) :
              \E r \in GensOf(S, k, i, FALSE) : g <= r
    LiveRun(k, i) == LiveIn(RunOfKey(k), k, i)
    LiveAll(k, i) == LiveIn(ElemsOfKey(k), k, i)

    \* The generation to stamp on a resurrecting record (spec §6.4): one past the
    \* newest superseding tombstone, else the counter's current value.
    TombFloor(k, i) ==
        IF GensOf(RunOfKey(k), k, i, TRUE) = {} THEN 0
        ELSE MaxOfSet(GensOf(RunOfKey(k), k, i, TRUE)) + 1

    \* --- flatten helpers ----------------------------------------------------
    Flattenable == { s \in Shards : exists[s] /\ ~drained[s] /\ s > 1 /\ s < chain }
    FirstFreeFor(s, k) ==
        IF \E j \in 0..(Cap-1) : slot[s][(Home[k] + j) % Cap] = Empty
        THEN (Home[k] + FirstEmptyFrom(s, Home[k])) % Cap
        ELSE 0 - 1

    IntendedPairs == UNION { { <<Work[p][n].key, Work[p][n].id>>
                                 : n \in 1..Len(Work[p]) } : p \in Producers }
  }

  \* ---------------------------------------------------------------------
  \* PRODUCERS: put (spec §6.4) and evict (spec §6.5). Both are INSERTS; the
  \* structure has no other write path.
  \* ---------------------------------------------------------------------
  fair process (prod \in Producers)
    variables wi = 1, ky = 0, idt = 0, elem = Empty, gnew = 0,
              sh = 1, ix = 0, pr = 0, nObs = 1;
  {
   PLoop:
    while (wi <= Len(Work[self])) {
      ky  := Work[self][wi].key;
      idt := Work[self][wi].id;
     PDecide:
      if (Work[self][wi].op = "put") {
        if (LiveRun(ky, idt)) {
          \* Already live: return `exists`. NOTHING IS WRITTEN (spec §6.4.1).
          lastOp[ky][idt] := "put";
          wi := wi + 1;
          goto PLoop;
        } else if (MaxNum(gcount, TombFloor(ky, idt)) > MaxGen) {
          saturated := TRUE;
          wi := wi + 1;
          goto PLoop;
        } else {
          gnew := MaxNum(gcount, TombFloor(ky, idt));
          gcount := MaxNum(gcount, TombFloor(ky, idt));
          elem := [key |-> ky, id |-> idt, gen |-> gnew, tomb |-> FALSE];
          goto PStart;
        };
      } else if (gcount + 1 > MaxGen) {
        saturated := TRUE;
        wi := wi + 1;
        goto PLoop;
      } else {
        \* Eviction allocates a FRESH generation, strictly above every stamped
        \* one, so the strict "newer than" of the liveness rule can decide.
        gcount := gcount + 1;
        elem := [key |-> ky, id |-> idt, gen |-> gcount, tomb |-> TRUE];
        goto PStart;   \* `gcount` here is the value just assigned (PlusCal
                       \* substitutes the primed variable), i.e. the FRESH one
      };
     PStart:
      nObs := chain;
      sh   := chain;
      ix   := Home[ky];         \* HOME SLOT FROM THE PRIMARY KEY ALONE
      pr   := 0;
     PProbe:
      while (pr < Cap) {
        if (slot[sh][ix] = Empty) {
          goto PReserve;
        } else if (slot[sh][ix] = elem) {
          committed := committed \cup {elem};
          lastOp[ky][idt] := IF elem.tomb THEN "evict" ELSE "put";
          wi := wi + 1;
          goto PLoop;
        } else {
          ix := (ix + 1) % Cap;                \* probe past a foreign element
          pr := pr + 1;
        };
      };
      goto PNeedGrow;
     PReserve:
      if (occ[sh] >= Cap) { goto PNeedGrow; };
     PPublish:
      if (slot[sh][ix] = Empty) {
        slot[sh][ix] := elem;                  \* CAS 0 -> element (win)
        occ[sh] := occ[sh] + 1;
        committed := committed \cup {elem};
        lastOp[ky][idt] := IF elem.tomb THEN "evict" ELSE "put";
        wi := wi + 1;
        goto PLoop;
      } else if (slot[sh][ix] = elem) {
        committed := committed \cup {elem};
        lastOp[ky][idt] := IF elem.tomb THEN "evict" ELSE "put";
        wi := wi + 1;
        goto PLoop;
      } else {
        ix := (ix + 1) % Cap;
        pr := pr + 1;
        goto PProbe;
      };
     PNeedGrow:
      if (nObs + 1 > MaxShards) {
        saturated := TRUE;
        wi := wi + 1;
        goto PLoop;
      } else if (chain > nObs) {
        goto PRetry;
      } else {
        if (~exists[nObs + 1]) { exists[nObs + 1] := TRUE; };
       PBump:
        if (chain < nObs + 1) { chain := nObs + 1; };
        goto PRetry;
      };
     PRetry:
      \* Re-observe the chain count, exactly as `insert`'s `while true` loop does
      \* (`let n = chainCount(s)` at the top of every iteration). Carrying a STALE
      \* `nObs` across a retry would let a producer conclude "someone already grew"
      \* forever while the shard it retries into is also full -- a livelock the
      \* real code cannot have, and which TLC does find if `nObs` is not refreshed.
      nObs := chain;
      sh := chain;
      ix := Home[ky];
      pr := 0;
      goto PProbe;
    };
   PFin:
    finished := finished + 1;
  }

  \* ---------------------------------------------------------------------
  \* FLATTENER (spec §6.7): copy every element of an older shard FORWARD, THEN
  \* mark it drained, THEN unlink it. The ordering is the entire safety
  \* argument, and the invariants below are what make it checkable.
  \* ---------------------------------------------------------------------
  fair process (flat = 98)
    variables fs = 0, fi = 0, fe = Empty, ff = 0;
  {
   FStart:
    if (~FlattenEnabled) { goto FDone; } else { goto FWait; };
   FWait:
    await (Flattenable # {}) \/ (finished = NumProducers);
   FPick:
    if (Flattenable = {}) { goto FDone; } else { goto FTake; };
   FTake:
    with (s \in Flattenable) { fs := s; };
    fi := 0;
   FCopy:
    while (fi < Cap) {
      if (slot[fs][fi] # Empty /\ ~(slot[fs][fi] \in PublishedIn(chain))) {
        fe := slot[fs][fi];
        ff := FirstFreeFor(chain, slot[fs][fi].key);
        if (ff < 0) {
          goto FGrow;                 \* destination full: grow, then RETRY this
        } else {                      \* element -- never drop, never drain early
          slot[chain][ff] := fe;
          occ[chain] := occ[chain] + 1;
          fi := fi + 1;
        };
      } else {
        fi := fi + 1;
      };
    };
    goto FDrain;
   FGrow:
    if (chain + 1 > MaxShards) {
      saturated := TRUE;              \* out of shards: abandon the flatten
      goto FDone;                     \* WITHOUT draining -- nothing is lost
    } else {
      if (~exists[chain + 1]) { exists[chain + 1] := TRUE; };
      goto FBump;
    };
   FBump:
    chain := chain + 1;
    goto FCopy;                       \* retry the same element, now with room
   FDrain:
    drained[fs] := TRUE;      \* only now may a reader skip the shard
   FRetire:
    exists[fs] := FALSE;      \* unlink; an already-mapped reader keeps its view
   FDone:
    skip;
  }

  \* ---------------------------------------------------------------------
  \* READER: one full chain walk, OLDEST SHARD FIRST, racing the flattener.
  \* ---------------------------------------------------------------------
  fair process (rdr = 97)
    variables rs = 1;
  {
   RStart:
    if (~ReaderEnabled) {
      goto RDone;
    } else {
      rstart := AllPublished; \* what was observable when this walk began
      rs := 1;
      rseen := {};
      goto RStep;
    };
   RStep:
    while (rs <= MaxShards) {
      if (exists[rs] /\ ~drained[rs]) { rseen := rseen \cup PublishedIn(rs); };
      rs := rs + 1;
    };
   RFin:
    rdone := TRUE;
   RDone:
    skip;
  }
}
*)
\* BEGIN TRANSLATION (chksum(pcal) = "98498330" /\ chksum(tla) = "a9ac8973")
VARIABLES slot, occ, exists, drained, chain, gcount, lastOp, committed, 
          finished, saturated, rdone, rstart, rseen, pc

(* define statement *)
LiveShards  == { s \in Shards : exists[s] /\ ~drained[s] }
PublishedIn(s) == { slot[s][i] : i \in { j \in 0..(Cap-1) : slot[s][j] # Empty } }
AllPublished == UNION { PublishedIn(s) : s \in LiveShards }


FirstEmptyFrom(s, h) ==
    IF \E j \in 0..(Cap-1) : slot[s][(h + j) % Cap] = Empty
    THEN CHOOSE j \in 0..(Cap-1) :
            /\ slot[s][(h + j) % Cap] = Empty
            /\ \A m \in 0..(j-1) : slot[s][(h + m) % Cap] # Empty
    ELSE Cap
RunFrom(s, h) == { slot[s][(h + j) % Cap] :
                     j \in 0..(FirstEmptyFrom(s, h) - 1) }




RunOfKey(k) == UNION { { e \in RunFrom(s, Home[k]) : e.key = k }
                         : s \in LiveShards }
ElemsOfKey(k) == { e \in AllPublished : e.key = k }


GensOf(S, k, i, t) == { e.gen : e \in { x \in S : x.key = k /\ x.id = i
                                                  /\ x.tomb = t } }
LiveIn(S, k, i) ==
    /\ GensOf(S, k, i, FALSE) # {}
    /\ \A g \in GensOf(S, k, i, TRUE) :
          \E r \in GensOf(S, k, i, FALSE) : g <= r
LiveRun(k, i) == LiveIn(RunOfKey(k), k, i)
LiveAll(k, i) == LiveIn(ElemsOfKey(k), k, i)



TombFloor(k, i) ==
    IF GensOf(RunOfKey(k), k, i, TRUE) = {} THEN 0
    ELSE MaxOfSet(GensOf(RunOfKey(k), k, i, TRUE)) + 1


Flattenable == { s \in Shards : exists[s] /\ ~drained[s] /\ s > 1 /\ s < chain }
FirstFreeFor(s, k) ==
    IF \E j \in 0..(Cap-1) : slot[s][(Home[k] + j) % Cap] = Empty
    THEN (Home[k] + FirstEmptyFrom(s, Home[k])) % Cap
    ELSE 0 - 1

IntendedPairs == UNION { { <<Work[p][n].key, Work[p][n].id>>
                             : n \in 1..Len(Work[p]) } : p \in Producers }

VARIABLES wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, ff, rs

vars == << slot, occ, exists, drained, chain, gcount, lastOp, committed, 
           finished, saturated, rdone, rstart, rseen, pc, wi, ky, idt, elem, 
           gnew, sh, ix, pr, nObs, fs, fi, fe, ff, rs >>

ProcSet == (Producers) \cup {98} \cup {97}

Init == (* Global variables *)
        /\ slot = [s \in Shards |-> [i \in 0..(Cap-1) |-> Empty]]
        /\ occ = [s \in Shards |-> 0]
        /\ exists = [s \in Shards |-> (s = 1)]
        /\ drained = [s \in Shards |-> FALSE]
        /\ chain = 1
        /\ gcount = 0
        /\ lastOp = [k \in Keys |-> [i \in Ids |-> "none"]]
        /\ committed = {}
        /\ finished = 0
        /\ saturated = FALSE
        /\ rdone = FALSE
        /\ rstart = {}
        /\ rseen = {}
        (* Process prod *)
        /\ wi = [self \in Producers |-> 1]
        /\ ky = [self \in Producers |-> 0]
        /\ idt = [self \in Producers |-> 0]
        /\ elem = [self \in Producers |-> Empty]
        /\ gnew = [self \in Producers |-> 0]
        /\ sh = [self \in Producers |-> 1]
        /\ ix = [self \in Producers |-> 0]
        /\ pr = [self \in Producers |-> 0]
        /\ nObs = [self \in Producers |-> 1]
        (* Process flat *)
        /\ fs = 0
        /\ fi = 0
        /\ fe = Empty
        /\ ff = 0
        (* Process rdr *)
        /\ rs = 1
        /\ pc = [self \in ProcSet |-> CASE self \in Producers -> "PLoop"
                                        [] self = 98 -> "FStart"
                                        [] self = 97 -> "RStart"]

PLoop(self) == /\ pc[self] = "PLoop"
               /\ IF wi[self] <= Len(Work[self])
                     THEN /\ ky' = [ky EXCEPT ![self] = Work[self][wi[self]].key]
                          /\ idt' = [idt EXCEPT ![self] = Work[self][wi[self]].id]
                          /\ pc' = [pc EXCEPT ![self] = "PDecide"]
                     ELSE /\ pc' = [pc EXCEPT ![self] = "PFin"]
                          /\ UNCHANGED << ky, idt >>
               /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, 
                               lastOp, committed, finished, saturated, rdone, 
                               rstart, rseen, wi, elem, gnew, sh, ix, pr, nObs, 
                               fs, fi, fe, ff, rs >>

PDecide(self) == /\ pc[self] = "PDecide"
                 /\ IF Work[self][wi[self]].op = "put"
                       THEN /\ IF LiveRun(ky[self], idt[self])
                                  THEN /\ lastOp' = [lastOp EXCEPT ![ky[self]][idt[self]] = "put"]
                                       /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                                       /\ UNCHANGED << gcount, saturated, elem, 
                                                       gnew >>
                                  ELSE /\ IF MaxNum(gcount, TombFloor(ky[self], idt[self])) > MaxGen
                                             THEN /\ saturated' = TRUE
                                                  /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                                  /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                                                  /\ UNCHANGED << gcount, elem, 
                                                                  gnew >>
                                             ELSE /\ gnew' = [gnew EXCEPT ![self] = MaxNum(gcount, TombFloor(ky[self], idt[self]))]
                                                  /\ gcount' = MaxNum(gcount, TombFloor(ky[self], idt[self]))
                                                  /\ elem' = [elem EXCEPT ![self] = [key |-> ky[self], id |-> idt[self], gen |-> gnew'[self], tomb |-> FALSE]]
                                                  /\ pc' = [pc EXCEPT ![self] = "PStart"]
                                                  /\ UNCHANGED << saturated, 
                                                                  wi >>
                                       /\ UNCHANGED lastOp
                       ELSE /\ IF gcount + 1 > MaxGen
                                  THEN /\ saturated' = TRUE
                                       /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                                       /\ UNCHANGED << gcount, elem >>
                                  ELSE /\ gcount' = gcount + 1
                                       /\ elem' = [elem EXCEPT ![self] = [key |-> ky[self], id |-> idt[self], gen |-> gcount', tomb |-> TRUE]]
                                       /\ pc' = [pc EXCEPT ![self] = "PStart"]
                                       /\ UNCHANGED << saturated, wi >>
                            /\ UNCHANGED << lastOp, gnew >>
                 /\ UNCHANGED << slot, occ, exists, drained, chain, committed, 
                                 finished, rdone, rstart, rseen, ky, idt, sh, 
                                 ix, pr, nObs, fs, fi, fe, ff, rs >>

PStart(self) == /\ pc[self] = "PStart"
                /\ nObs' = [nObs EXCEPT ![self] = chain]
                /\ sh' = [sh EXCEPT ![self] = chain]
                /\ ix' = [ix EXCEPT ![self] = Home[ky[self]]]
                /\ pr' = [pr EXCEPT ![self] = 0]
                /\ pc' = [pc EXCEPT ![self] = "PProbe"]
                /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, 
                                lastOp, committed, finished, saturated, rdone, 
                                rstart, rseen, wi, ky, idt, elem, gnew, fs, fi, 
                                fe, ff, rs >>

PProbe(self) == /\ pc[self] = "PProbe"
                /\ IF pr[self] < Cap
                      THEN /\ IF slot[sh[self]][ix[self]] = Empty
                                 THEN /\ pc' = [pc EXCEPT ![self] = "PReserve"]
                                      /\ UNCHANGED << lastOp, committed, wi, 
                                                      ix, pr >>
                                 ELSE /\ IF slot[sh[self]][ix[self]] = elem[self]
                                            THEN /\ committed' = (committed \cup {elem[self]})
                                                 /\ lastOp' = [lastOp EXCEPT ![ky[self]][idt[self]] = IF elem[self].tomb THEN "evict" ELSE "put"]
                                                 /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                                 /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                                                 /\ UNCHANGED << ix, pr >>
                                            ELSE /\ ix' = [ix EXCEPT ![self] = (ix[self] + 1) % Cap]
                                                 /\ pr' = [pr EXCEPT ![self] = pr[self] + 1]
                                                 /\ pc' = [pc EXCEPT ![self] = "PProbe"]
                                                 /\ UNCHANGED << lastOp, 
                                                                 committed, wi >>
                      ELSE /\ pc' = [pc EXCEPT ![self] = "PNeedGrow"]
                           /\ UNCHANGED << lastOp, committed, wi, ix, pr >>
                /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, 
                                finished, saturated, rdone, rstart, rseen, ky, 
                                idt, elem, gnew, sh, nObs, fs, fi, fe, ff, rs >>

PReserve(self) == /\ pc[self] = "PReserve"
                  /\ IF occ[sh[self]] >= Cap
                        THEN /\ pc' = [pc EXCEPT ![self] = "PNeedGrow"]
                        ELSE /\ pc' = [pc EXCEPT ![self] = "PPublish"]
                  /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, 
                                  lastOp, committed, finished, saturated, 
                                  rdone, rstart, rseen, wi, ky, idt, elem, 
                                  gnew, sh, ix, pr, nObs, fs, fi, fe, ff, rs >>

PPublish(self) == /\ pc[self] = "PPublish"
                  /\ IF slot[sh[self]][ix[self]] = Empty
                        THEN /\ slot' = [slot EXCEPT ![sh[self]][ix[self]] = elem[self]]
                             /\ occ' = [occ EXCEPT ![sh[self]] = occ[sh[self]] + 1]
                             /\ committed' = (committed \cup {elem[self]})
                             /\ lastOp' = [lastOp EXCEPT ![ky[self]][idt[self]] = IF elem[self].tomb THEN "evict" ELSE "put"]
                             /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                             /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                             /\ UNCHANGED << ix, pr >>
                        ELSE /\ IF slot[sh[self]][ix[self]] = elem[self]
                                   THEN /\ committed' = (committed \cup {elem[self]})
                                        /\ lastOp' = [lastOp EXCEPT ![ky[self]][idt[self]] = IF elem[self].tomb THEN "evict" ELSE "put"]
                                        /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                        /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                                        /\ UNCHANGED << ix, pr >>
                                   ELSE /\ ix' = [ix EXCEPT ![self] = (ix[self] + 1) % Cap]
                                        /\ pr' = [pr EXCEPT ![self] = pr[self] + 1]
                                        /\ pc' = [pc EXCEPT ![self] = "PProbe"]
                                        /\ UNCHANGED << lastOp, committed, wi >>
                             /\ UNCHANGED << slot, occ >>
                  /\ UNCHANGED << exists, drained, chain, gcount, finished, 
                                  saturated, rdone, rstart, rseen, ky, idt, 
                                  elem, gnew, sh, nObs, fs, fi, fe, ff, rs >>

PNeedGrow(self) == /\ pc[self] = "PNeedGrow"
                   /\ IF nObs[self] + 1 > MaxShards
                         THEN /\ saturated' = TRUE
                              /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                              /\ pc' = [pc EXCEPT ![self] = "PLoop"]
                              /\ UNCHANGED exists
                         ELSE /\ IF chain > nObs[self]
                                    THEN /\ pc' = [pc EXCEPT ![self] = "PRetry"]
                                         /\ UNCHANGED exists
                                    ELSE /\ IF ~exists[nObs[self] + 1]
                                               THEN /\ exists' = [exists EXCEPT ![nObs[self] + 1] = TRUE]
                                               ELSE /\ TRUE
                                                    /\ UNCHANGED exists
                                         /\ pc' = [pc EXCEPT ![self] = "PBump"]
                              /\ UNCHANGED << saturated, wi >>
                   /\ UNCHANGED << slot, occ, drained, chain, gcount, lastOp, 
                                   committed, finished, rdone, rstart, rseen, 
                                   ky, idt, elem, gnew, sh, ix, pr, nObs, fs, 
                                   fi, fe, ff, rs >>

PBump(self) == /\ pc[self] = "PBump"
               /\ IF chain < nObs[self] + 1
                     THEN /\ chain' = nObs[self] + 1
                     ELSE /\ TRUE
                          /\ chain' = chain
               /\ pc' = [pc EXCEPT ![self] = "PRetry"]
               /\ UNCHANGED << slot, occ, exists, drained, gcount, lastOp, 
                               committed, finished, saturated, rdone, rstart, 
                               rseen, wi, ky, idt, elem, gnew, sh, ix, pr, 
                               nObs, fs, fi, fe, ff, rs >>

PRetry(self) == /\ pc[self] = "PRetry"
                /\ nObs' = [nObs EXCEPT ![self] = chain]
                /\ sh' = [sh EXCEPT ![self] = chain]
                /\ ix' = [ix EXCEPT ![self] = Home[ky[self]]]
                /\ pr' = [pr EXCEPT ![self] = 0]
                /\ pc' = [pc EXCEPT ![self] = "PProbe"]
                /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, 
                                lastOp, committed, finished, saturated, rdone, 
                                rstart, rseen, wi, ky, idt, elem, gnew, fs, fi, 
                                fe, ff, rs >>

PFin(self) == /\ pc[self] = "PFin"
              /\ finished' = finished + 1
              /\ pc' = [pc EXCEPT ![self] = "Done"]
              /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, 
                              lastOp, committed, saturated, rdone, rstart, 
                              rseen, wi, ky, idt, elem, gnew, sh, ix, pr, nObs, 
                              fs, fi, fe, ff, rs >>

prod(self) == PLoop(self) \/ PDecide(self) \/ PStart(self) \/ PProbe(self)
                 \/ PReserve(self) \/ PPublish(self) \/ PNeedGrow(self)
                 \/ PBump(self) \/ PRetry(self) \/ PFin(self)

FStart == /\ pc[98] = "FStart"
          /\ IF ~FlattenEnabled
                THEN /\ pc' = [pc EXCEPT ![98] = "FDone"]
                ELSE /\ pc' = [pc EXCEPT ![98] = "FWait"]
          /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                          committed, finished, saturated, rdone, rstart, rseen, 
                          wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fs, fi, 
                          fe, ff, rs >>

FWait == /\ pc[98] = "FWait"
         /\ (Flattenable # {}) \/ (finished = NumProducers)
         /\ pc' = [pc EXCEPT ![98] = "FPick"]
         /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                         committed, finished, saturated, rdone, rstart, rseen, 
                         wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, 
                         ff, rs >>

FPick == /\ pc[98] = "FPick"
         /\ IF Flattenable = {}
               THEN /\ pc' = [pc EXCEPT ![98] = "FDone"]
               ELSE /\ pc' = [pc EXCEPT ![98] = "FTake"]
         /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                         committed, finished, saturated, rdone, rstart, rseen, 
                         wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, 
                         ff, rs >>

FTake == /\ pc[98] = "FTake"
         /\ \E s \in Flattenable:
              fs' = s
         /\ fi' = 0
         /\ pc' = [pc EXCEPT ![98] = "FCopy"]
         /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                         committed, finished, saturated, rdone, rstart, rseen, 
                         wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fe, ff, rs >>

FCopy == /\ pc[98] = "FCopy"
         /\ IF fi < Cap
               THEN /\ IF slot[fs][fi] # Empty /\ ~(slot[fs][fi] \in PublishedIn(chain))
                          THEN /\ fe' = slot[fs][fi]
                               /\ ff' = FirstFreeFor(chain, slot[fs][fi].key)
                               /\ IF ff' < 0
                                     THEN /\ pc' = [pc EXCEPT ![98] = "FGrow"]
                                          /\ UNCHANGED << slot, occ, fi >>
                                     ELSE /\ slot' = [slot EXCEPT ![chain][ff'] = fe']
                                          /\ occ' = [occ EXCEPT ![chain] = occ[chain] + 1]
                                          /\ fi' = fi + 1
                                          /\ pc' = [pc EXCEPT ![98] = "FCopy"]
                          ELSE /\ fi' = fi + 1
                               /\ pc' = [pc EXCEPT ![98] = "FCopy"]
                               /\ UNCHANGED << slot, occ, fe, ff >>
               ELSE /\ pc' = [pc EXCEPT ![98] = "FDrain"]
                    /\ UNCHANGED << slot, occ, fi, fe, ff >>
         /\ UNCHANGED << exists, drained, chain, gcount, lastOp, committed, 
                         finished, saturated, rdone, rstart, rseen, wi, ky, 
                         idt, elem, gnew, sh, ix, pr, nObs, fs, rs >>

FGrow == /\ pc[98] = "FGrow"
         /\ IF chain + 1 > MaxShards
               THEN /\ saturated' = TRUE
                    /\ pc' = [pc EXCEPT ![98] = "FDone"]
                    /\ UNCHANGED exists
               ELSE /\ IF ~exists[chain + 1]
                          THEN /\ exists' = [exists EXCEPT ![chain + 1] = TRUE]
                          ELSE /\ TRUE
                               /\ UNCHANGED exists
                    /\ pc' = [pc EXCEPT ![98] = "FBump"]
                    /\ UNCHANGED saturated
         /\ UNCHANGED << slot, occ, drained, chain, gcount, lastOp, committed, 
                         finished, rdone, rstart, rseen, wi, ky, idt, elem, 
                         gnew, sh, ix, pr, nObs, fs, fi, fe, ff, rs >>

FBump == /\ pc[98] = "FBump"
         /\ chain' = chain + 1
         /\ pc' = [pc EXCEPT ![98] = "FCopy"]
         /\ UNCHANGED << slot, occ, exists, drained, gcount, lastOp, committed, 
                         finished, saturated, rdone, rstart, rseen, wi, ky, 
                         idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, ff, rs >>

FDrain == /\ pc[98] = "FDrain"
          /\ drained' = [drained EXCEPT ![fs] = TRUE]
          /\ pc' = [pc EXCEPT ![98] = "FRetire"]
          /\ UNCHANGED << slot, occ, exists, chain, gcount, lastOp, committed, 
                          finished, saturated, rdone, rstart, rseen, wi, ky, 
                          idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, ff, 
                          rs >>

FRetire == /\ pc[98] = "FRetire"
           /\ exists' = [exists EXCEPT ![fs] = FALSE]
           /\ pc' = [pc EXCEPT ![98] = "FDone"]
           /\ UNCHANGED << slot, occ, drained, chain, gcount, lastOp, 
                           committed, finished, saturated, rdone, rstart, 
                           rseen, wi, ky, idt, elem, gnew, sh, ix, pr, nObs, 
                           fs, fi, fe, ff, rs >>

FDone == /\ pc[98] = "FDone"
         /\ TRUE
         /\ pc' = [pc EXCEPT ![98] = "Done"]
         /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                         committed, finished, saturated, rdone, rstart, rseen, 
                         wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, 
                         ff, rs >>

flat == FStart \/ FWait \/ FPick \/ FTake \/ FCopy \/ FGrow \/ FBump
           \/ FDrain \/ FRetire \/ FDone

RStart == /\ pc[97] = "RStart"
          /\ IF ~ReaderEnabled
                THEN /\ pc' = [pc EXCEPT ![97] = "RDone"]
                     /\ UNCHANGED << rstart, rseen, rs >>
                ELSE /\ rstart' = AllPublished
                     /\ rs' = 1
                     /\ rseen' = {}
                     /\ pc' = [pc EXCEPT ![97] = "RStep"]
          /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                          committed, finished, saturated, rdone, wi, ky, idt, 
                          elem, gnew, sh, ix, pr, nObs, fs, fi, fe, ff >>

RStep == /\ pc[97] = "RStep"
         /\ IF rs <= MaxShards
               THEN /\ IF exists[rs] /\ ~drained[rs]
                          THEN /\ rseen' = (rseen \cup PublishedIn(rs))
                          ELSE /\ TRUE
                               /\ rseen' = rseen
                    /\ rs' = rs + 1
                    /\ pc' = [pc EXCEPT ![97] = "RStep"]
               ELSE /\ pc' = [pc EXCEPT ![97] = "RFin"]
                    /\ UNCHANGED << rseen, rs >>
         /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                         committed, finished, saturated, rdone, rstart, wi, ky, 
                         idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, ff >>

RFin == /\ pc[97] = "RFin"
        /\ rdone' = TRUE
        /\ pc' = [pc EXCEPT ![97] = "RDone"]
        /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                        committed, finished, saturated, rstart, rseen, wi, ky, 
                        idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, ff, rs >>

RDone == /\ pc[97] = "RDone"
         /\ TRUE
         /\ pc' = [pc EXCEPT ![97] = "Done"]
         /\ UNCHANGED << slot, occ, exists, drained, chain, gcount, lastOp, 
                         committed, finished, saturated, rdone, rstart, rseen, 
                         wi, ky, idt, elem, gnew, sh, ix, pr, nObs, fs, fi, fe, 
                         ff, rs >>

rdr == RStart \/ RStep \/ RFin \/ RDone

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == flat \/ rdr
           \/ (\E self \in Producers: prod(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Producers : WF_vars(prod(self))
        /\ WF_vars(flat)
        /\ WF_vars(rdr)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

--------------------------------------------------------------------------------
\* Safety invariants (checked at every reachable state).

TypeOK ==
    /\ chain \in 1..MaxShards
    /\ gcount \in 0..MaxGen
    /\ \A s \in Shards : occ[s] \in 0..Cap

\* Carried over from `shm_gset.tla` — still true under the keyed discipline.
NoPhantom == \A e \in AllPublished : <<e.key, e.id>> \in IntendedPairs
NoLostElement == committed \subseteq AllPublished
AnchorNeverRetired == exists[1] /\ ~drained[1]     \* shard0 holds the control block

--------------------------------------------------------------------------------
\* (1) PROBE-RUN COMPLETENESS.
\*
\* Enumeration from a home slot yields EXACTLY the elements with that primary
\* key. Per shard: the walk from Home[k] to the first empty slot, filtered on the
\* stored key, equals the set of published elements of that key in that shard.
\* Both directions matter: `\subseteq` is "no phantom in the run", `\supseteq` is
\* "no element missed and no early termination". There is no stored chain, no
\* chain-length counter and no pointer update anywhere in the model — the run IS
\* the enumeration.
RunEnumerationExact ==
    \A s \in LiveShards : \A k \in Keys :
        { e \in RunFrom(s, Home[k]) : e.key = k } =
        { e \in PublishedIn(s) : e.key = k }

--------------------------------------------------------------------------------
\* (2) RUN INTEGRITY ACROSS SHARD GROWTH.
\*
\* Growth splits one primary key's elements across shards (a producer that hits a
\* full shard retries the SAME element in the newer one). Enumeration over the
\* union of per-shard walks must still be exactly the key's element set.
RunIntegrityAcrossShards == \A k \in Keys : RunOfKey(k) = ElemsOfKey(k)

--------------------------------------------------------------------------------
\* (3) TOMBSTONE ORDERING.
\*
\* EnumerationDecidesLikeUnion: the liveness verdict reached through the probe
\* run equals the verdict an omniscient observer reaches from every published
\* element — i.e. the enumeration is a sound basis for the eviction rule, in
\* every interleaving and across every shard boundary.
EnumerationDecidesLikeUnion ==
    \A k \in Keys : \A i \in Ids : LiveRun(k, i) = LiveAll(k, i)

\* GenerationInvariant: every stamped generation is dominated by the single
\* global counter in shard0. This is what makes "newer" a TOTAL order over the
\* whole chain (spec §6.5 rejects per-shard counters for exactly this reason) and
\* it is the premise the two properties below rely on.
GenerationInvariant == \A e \in AllPublished : e.gen <= gcount

\* EvictionEffective / PutEffective: the protocol actually decides. After an
\* eviction completes the key reads DEAD; after a put completes it reads LIVE —
\* regardless of the order in which records and tombstones were inserted, of
\* which shard each landed in, and of what other keys did in the same probe run.
\*
\* These hold when operations on a given (key, id) are serialised, which the
\* configurations enforce by giving each pair to exactly one producer. (The spec
\* explicitly ACCEPTS the racing case — "if they race with different generations,
\* both elements exist and the newer one wins" — so asserting them under
\* concurrent writers to one key would contradict the spec, not the code.)
EvictionEffective ==
    \A k \in Keys : \A i \in Ids : (lastOp[k][i] = "evict") => ~LiveRun(k, i)
PutEffective ==
    \A k \in Keys : \A i \in Ids : (lastOp[k][i] = "put") => LiveRun(k, i)

--------------------------------------------------------------------------------
\* (4) FLATTEN-THEN-RETIRE SAFETY.
\*
\* FlattenDrainsOnlyCopied: a shard is marked drained ONLY in states where every
\* element it holds is also present in a live shard. The drain flag is what
\* permits a reader to skip the shard, so this is the precondition that makes
\* skipping safe; the model sets it strictly after the copies (FCopy -> FDrain).
FlattenDrainsOnlyCopied ==
    \A s \in Shards :
      drained[s] =>
        \A i \in 0..(Cap-1) :
          (slot[s][i] # Empty) => (\E t \in LiveShards : slot[s][i] \in PublishedIn(t))

\* ReaderCompleteUnderFlatten: a reader that walks the chain OLDEST SHARD FIRST,
\* concurrently with copy-forward / drain / retire, ends its walk having seen
\* everything that was observable when the walk began.
\*
\* The order is load-bearing and this invariant is what proves it. Flip the
\* reader to newest-first and TLC finds a counterexample: the flattener copies an
\* element forward AFTER the reader has passed the destination and drains the
\* source BEFORE the reader reaches it, so the reader sees it in neither.
\*
\* NOTE the reader's bound: RStep runs to MaxShards, a CONSTANT, so the modelled
\* reader visits every shard INCLUDING ones created after its walk began. That is
\* a proof obligation on the implementation, not an accident of the model. A walk
\* that snapshots the chain length at entry is NOT the reader proved here: it
\* skips the drained source while never reaching the destination the flattener
\* grew the chain to create, and loses an element that was observable at entry.
\* `withPrimaryKeyHash` and `contains` re-read `chainCount` per step for exactly
\* this reason; test G3 in tests/test_shm_gset_keyed.nim pins the behaviour.
ReaderCompleteUnderFlatten == rdone => (rstart \subseteq rseen)

\* CannotSaturate: with the chosen bounds nothing hits the MaxShards / MaxGen
\* wall, so the invariants above are exercised on the real paths rather than
\* masked by an early-out. If TLC reports this violated, raise the bounds.
CannotSaturate == saturated = FALSE

--------------------------------------------------------------------------------
\* Action / temporal properties.

\* ObservabilityMonotone: nothing that is observable ever stops being observable.
\* This is the grow-only (join-semilattice) property surviving eviction AND
\* flattening: eviction adds a tombstone rather than removing anything, and a
\* retirement is preceded by a copy forward.
ObservabilityMonotone == [][ AllPublished \subseteq AllPublished' ]_vars

\* Every key an operation completed on eventually settles on its verdict and
\* stays there for the rest of the trace (grow-only => the verdict is stable once
\* the last operation on that key has completed).
EventuallyStable == <>[]( \A k \in Keys : \A i \in Ids :
                            LiveRun(k, i) = LiveAll(k, i) )

=================================================================================
