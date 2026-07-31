-------------------------------- MODULE shm_gset --------------------------------
(***************************************************************************)
(* TLA+/PlusCal model of the `nim-shm-gset` shared-memory G-Set protocol     *)
(* (design spec io-mon-Lossless-Event-Capture §4.5(a)).                     *)
(*                                                                          *)
(* WHAT THIS MODELS — the LOGICAL protocol under interleaving semantics:    *)
(*   * empty-slot claim (CAS 0 -> element) with linear probing,             *)
(*   * arena reserve + publish-before-CAS (write record, then publish),     *)
(*   * growth-by-sharding: append a new shard file (idempotent link) then   *)
(*     bump the chain count; producers keep inserting into the newest shard,*)
(*   * the single-threaded reader's UNION over all existing shards,         *)
(*   * cross-shard duplicates (an element in an old shard re-inserted into a *)
(*     newer one) folding away under set union (the CRDT join),             *)
(*   * the reaper's flock guard (never GC a live run).                      *)
(*                                                                          *)
(* SCOPE / WHAT THIS DOES NOT MODEL — WEAK MEMORY. TLC explores SEQUENTIALLY*)
(* CONSISTENT interleavings; it does NOT reorder within a thread the way    *)
(* ARMv8/RISC-V can. The sufficiency of the specific release/acquire        *)
(* annotations (the torn-read / message-passing shapes) is proven SEPARATELY*)
(* by the herd7 litmus tests and the GenMC C11 core in ../litmus and ../core*)
(* This module proves the ALGORITHM is correct GIVEN correct ordering:      *)
(* no lost element, no phantom, exact union, chain integrity, idempotence,  *)
(* grow arbitration, reaper safety.                                         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Producers,   \* set of producer process ids
    Cap,         \* slots per shard (and arena record capacity), power of two
    MaxShards,   \* bound on chain length
    Home,        \* [Element -> 0..Cap-1] : each element's home slot
    Work         \* [Producer -> Seq(Element)] : each producer's intended inserts

Elements == DOMAIN Home
Shards == 1..MaxShards

ASSUME Cap \in Nat /\ Cap >= 1
ASSUME MaxShards \in Nat /\ MaxShards >= 1
ASSUME Home \in [Elements -> 0..(Cap-1)]

(* --algorithm shmgset {
  variables
    slot   = [s \in Shards |-> [i \in 0..(Cap-1) |-> 0]];   \* 0 = empty, else element
    occ    = [s \in Shards |-> 0];                          \* claimed slots per shard
    exists = [s \in Shards |-> (s = 1)];                    \* shard file present?
    chain  = 1;                                             \* chainCount (>=1)
    committed = {};                                         \* elements an insert returned OK for
    saturated = FALSE;                                      \* hit the MaxShards bound (bad => bounds too small)
    flockHeld = TRUE;                                       \* the live run holds shard0's flock
    reaped = FALSE;                                         \* reaper removed some shard

  define {
    ExistingShards == { s \in Shards : exists[s] }
    PublishedIn(s) == { slot[s][i] : i \in { j \in 0..(Cap-1) : slot[s][j] # 0 } }
    ReaderUnion    == UNION { PublishedIn(s) : s \in ExistingShards }
    IntendedOf(p)  == { Work[p][k] : k \in 1..Len(Work[p]) }
    IntendedAll    == UNION { IntendedOf(p) : p \in Producers }
  }

  fair process (prod \in Producers)
    variables wi = 1, elem = 0, sh = 1, idx = 0, probes = 0, nObs = 1;
  {
   Loop:
    while (wi <= Len(Work[self])) {
      elem   := Work[self][wi];
      nObs   := chain;            \* observe the chain count for this attempt
      sh     := chain;            \* newest shard id (contiguous => id == chain)
      idx    := Home[elem];
      probes := 0;
     Probe:
      while (probes < Cap) {
        if (slot[sh][idx] = 0) {
          goto Reserve;
        } else if (slot[sh][idx] = elem) {
          committed := committed \cup {elem};   \* idempotent: already present
          wi := wi + 1;
          goto Loop;
        } else {
          idx := (idx + 1) % Cap;               \* linear probe past a distinct key
          probes := probes + 1;
        };
      };
      goto NeedGrow;                            \* whole table probed => full
     Reserve:
      if (occ[sh] >= Cap) {
        goto NeedGrow;                          \* arena/table exhausted => grow
      };
      \* (arena record fully written here; the publish below is the release-CAS)
     Publish:
      if (slot[sh][idx] = 0) {
        slot[sh][idx] := elem;                  \* CAS 0 -> element (win)
        occ[sh] := occ[sh] + 1;
        committed := committed \cup {elem};
        wi := wi + 1;
        goto Loop;
      } else if (slot[sh][idx] = elem) {
        committed := committed \cup {elem};      \* racer published our element first
        wi := wi + 1;
        goto Loop;
      } else {
        idx := (idx + 1) % Cap;                  \* lost slot to a distinct key: probe on
        probes := probes + 1;
        goto Probe;
      };
     NeedGrow:
      if (nObs + 1 > MaxShards) {
        saturated := TRUE;                       \* bounds too small (should be unreachable)
        wi := wi + 1;
        goto Loop;
      } else if (chain > nObs) {
        \* someone already grew past our observed chain; just retry into newest
        goto Retry;
      } else {
        if (~exists[nObs + 1]) {
          exists[nObs + 1] := TRUE;              \* appendShardFile: idempotent link
        };
       Bump:
        if (chain < nObs + 1) { chain := nObs + 1; };  \* bumpChainCountTo(nObs+1)
        goto Retry;
      };
     Retry:
      sh     := chain;                           \* retry SAME element into the newest shard
      idx    := Home[elem];
      probes := 0;
      goto Probe;
    };
  }

  \* The cross-restart reaper. It may fire at any time but MUST refuse to GC a
  \* run that holds shard0's flock (design spec §4.3.4 / §4.5(c)). Here the run
  \* is live for the whole trace (flockHeld = TRUE), so a correct reaper never
  \* removes a shard; TLC checks the guard cannot be bypassed.
  fair process (reaper = 0) {
   Reap:
    if (~flockHeld) {
      exists := [s \in Shards |-> FALSE];
      reaped := TRUE;
    };
  }
}
*)
\* BEGIN TRANSLATION
VARIABLES slot, occ, exists, chain, committed, saturated, flockHeld, reaped, 
          pc

(* define statement *)
ExistingShards == { s \in Shards : exists[s] }
PublishedIn(s) == { slot[s][i] : i \in { j \in 0..(Cap-1) : slot[s][j] # 0 } }
ReaderUnion    == UNION { PublishedIn(s) : s \in ExistingShards }
IntendedOf(p)  == { Work[p][k] : k \in 1..Len(Work[p]) }
IntendedAll    == UNION { IntendedOf(p) : p \in Producers }

VARIABLES wi, elem, sh, idx, probes, nObs

vars == << slot, occ, exists, chain, committed, saturated, flockHeld, reaped, 
           pc, wi, elem, sh, idx, probes, nObs >>

ProcSet == (Producers) \cup {0}

Init == (* Global variables *)
        /\ slot = [s \in Shards |-> [i \in 0..(Cap-1) |-> 0]]
        /\ occ = [s \in Shards |-> 0]
        /\ exists = [s \in Shards |-> (s = 1)]
        /\ chain = 1
        /\ committed = {}
        /\ saturated = FALSE
        /\ flockHeld = TRUE
        /\ reaped = FALSE
        (* Process prod *)
        /\ wi = [self \in Producers |-> 1]
        /\ elem = [self \in Producers |-> 0]
        /\ sh = [self \in Producers |-> 1]
        /\ idx = [self \in Producers |-> 0]
        /\ probes = [self \in Producers |-> 0]
        /\ nObs = [self \in Producers |-> 1]
        /\ pc = [self \in ProcSet |-> CASE self \in Producers -> "Loop"
                                        [] self = 0 -> "Reap"]

Loop(self) == /\ pc[self] = "Loop"
              /\ IF wi[self] <= Len(Work[self])
                    THEN /\ elem' = [elem EXCEPT ![self] = Work[self][wi[self]]]
                         /\ nObs' = [nObs EXCEPT ![self] = chain]
                         /\ sh' = [sh EXCEPT ![self] = chain]
                         /\ idx' = [idx EXCEPT ![self] = Home[elem'[self]]]
                         /\ probes' = [probes EXCEPT ![self] = 0]
                         /\ pc' = [pc EXCEPT ![self] = "Probe"]
                    ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                         /\ UNCHANGED << elem, sh, idx, probes, nObs >>
              /\ UNCHANGED << slot, occ, exists, chain, committed, saturated, 
                              flockHeld, reaped, wi >>

Probe(self) == /\ pc[self] = "Probe"
               /\ IF probes[self] < Cap
                     THEN /\ IF slot[sh[self]][idx[self]] = 0
                                THEN /\ pc' = [pc EXCEPT ![self] = "Reserve"]
                                     /\ UNCHANGED << committed, wi, idx, 
                                                     probes >>
                                ELSE /\ IF slot[sh[self]][idx[self]] = elem[self]
                                           THEN /\ committed' = (committed \cup {elem[self]})
                                                /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                                /\ pc' = [pc EXCEPT ![self] = "Loop"]
                                                /\ UNCHANGED << idx, probes >>
                                           ELSE /\ idx' = [idx EXCEPT ![self] = (idx[self] + 1) % Cap]
                                                /\ probes' = [probes EXCEPT ![self] = probes[self] + 1]
                                                /\ pc' = [pc EXCEPT ![self] = "Probe"]
                                                /\ UNCHANGED << committed, wi >>
                     ELSE /\ pc' = [pc EXCEPT ![self] = "NeedGrow"]
                          /\ UNCHANGED << committed, wi, idx, probes >>
               /\ UNCHANGED << slot, occ, exists, chain, saturated, flockHeld, 
                               reaped, elem, sh, nObs >>

Reserve(self) == /\ pc[self] = "Reserve"
                 /\ IF occ[sh[self]] >= Cap
                       THEN /\ pc' = [pc EXCEPT ![self] = "NeedGrow"]
                       ELSE /\ pc' = [pc EXCEPT ![self] = "Publish"]
                 /\ UNCHANGED << slot, occ, exists, chain, committed, 
                                 saturated, flockHeld, reaped, wi, elem, sh, 
                                 idx, probes, nObs >>

Publish(self) == /\ pc[self] = "Publish"
                 /\ IF slot[sh[self]][idx[self]] = 0
                       THEN /\ slot' = [slot EXCEPT ![sh[self]][idx[self]] = elem[self]]
                            /\ occ' = [occ EXCEPT ![sh[self]] = occ[sh[self]] + 1]
                            /\ committed' = (committed \cup {elem[self]})
                            /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                            /\ pc' = [pc EXCEPT ![self] = "Loop"]
                            /\ UNCHANGED << idx, probes >>
                       ELSE /\ IF slot[sh[self]][idx[self]] = elem[self]
                                  THEN /\ committed' = (committed \cup {elem[self]})
                                       /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "Loop"]
                                       /\ UNCHANGED << idx, probes >>
                                  ELSE /\ idx' = [idx EXCEPT ![self] = (idx[self] + 1) % Cap]
                                       /\ probes' = [probes EXCEPT ![self] = probes[self] + 1]
                                       /\ pc' = [pc EXCEPT ![self] = "Probe"]
                                       /\ UNCHANGED << committed, wi >>
                            /\ UNCHANGED << slot, occ >>
                 /\ UNCHANGED << exists, chain, saturated, flockHeld, reaped, 
                                 elem, sh, nObs >>

NeedGrow(self) == /\ pc[self] = "NeedGrow"
                  /\ IF nObs[self] + 1 > MaxShards
                        THEN /\ saturated' = TRUE
                             /\ wi' = [wi EXCEPT ![self] = wi[self] + 1]
                             /\ pc' = [pc EXCEPT ![self] = "Loop"]
                             /\ UNCHANGED exists
                        ELSE /\ IF chain > nObs[self]
                                   THEN /\ pc' = [pc EXCEPT ![self] = "Retry"]
                                        /\ UNCHANGED exists
                                   ELSE /\ IF ~exists[nObs[self] + 1]
                                              THEN /\ exists' = [exists EXCEPT ![nObs[self] + 1] = TRUE]
                                              ELSE /\ TRUE
                                                   /\ UNCHANGED exists
                                        /\ pc' = [pc EXCEPT ![self] = "Bump"]
                             /\ UNCHANGED << saturated, wi >>
                  /\ UNCHANGED << slot, occ, chain, committed, flockHeld, 
                                  reaped, elem, sh, idx, probes, nObs >>

Bump(self) == /\ pc[self] = "Bump"
              /\ IF chain < nObs[self] + 1
                    THEN /\ chain' = nObs[self] + 1
                    ELSE /\ TRUE
                         /\ chain' = chain
              /\ pc' = [pc EXCEPT ![self] = "Retry"]
              /\ UNCHANGED << slot, occ, exists, committed, saturated, 
                              flockHeld, reaped, wi, elem, sh, idx, probes, 
                              nObs >>

Retry(self) == /\ pc[self] = "Retry"
               /\ sh' = [sh EXCEPT ![self] = chain]
               /\ idx' = [idx EXCEPT ![self] = Home[elem[self]]]
               /\ probes' = [probes EXCEPT ![self] = 0]
               /\ pc' = [pc EXCEPT ![self] = "Probe"]
               /\ UNCHANGED << slot, occ, exists, chain, committed, saturated, 
                               flockHeld, reaped, wi, elem, nObs >>

prod(self) == Loop(self) \/ Probe(self) \/ Reserve(self) \/ Publish(self)
                 \/ NeedGrow(self) \/ Bump(self) \/ Retry(self)

Reap == /\ pc[0] = "Reap"
        /\ IF ~flockHeld
              THEN /\ exists' = [s \in Shards |-> FALSE]
                   /\ reaped' = TRUE
              ELSE /\ TRUE
                   /\ UNCHANGED << exists, reaped >>
        /\ pc' = [pc EXCEPT ![0] = "Done"]
        /\ UNCHANGED << slot, occ, chain, committed, saturated, flockHeld, wi, 
                        elem, sh, idx, probes, nObs >>

reaper == Reap

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == reaper
           \/ (\E self \in Producers: prod(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Producers : WF_vars(prod(self))
        /\ WF_vars(reaper)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION

--------------------------------------------------------------------------------
\* Safety invariants (checked at every reachable state).

\* NoPhantom: the reader never sees an element nobody intended.
NoPhantom == ReaderUnion \subseteq IntendedAll

\* NoLostElement: every insert that returned success is in the reader's union.
NoLostElement == committed \subseteq ReaderUnion

\* ReaderSeesValidUnion: every published slot holds a real element; every
\* existing shard is within the chain; the reader union is always a subset of
\* the intended set (a valid, phantom-free view at any consistent read).
ReaderSeesValidUnion ==
    /\ \A s \in Shards : \A i \in 0..(Cap-1) :
         (slot[s][i] # 0) => (slot[s][i] \in Elements)
    /\ ReaderUnion \subseteq IntendedAll

\* ChainAcyclicNoLostShard: the shard files form a contiguous prefix 1..M with
\* no gap and no cycle (a G-Set chain is a simple prefix list), and the chain
\* COUNT is only ever bumped AFTER the file it counts already exists
\* (chain <= |existing|). The reverse window is legitimate and IS covered: a
\* freshly-linked shard whose chain-bump has not happened yet (exists[k] but
\* k > chain) is still discovered by the reader, which unions ExistingShards
\* (the directory scan of design spec §4.3.1), NOT 1..chain. That publish-before-
\* bump window is the crash-robustness property, so it must NOT be flagged.
ChainAcyclicNoLostShard ==
    /\ chain \in 1..MaxShards
    /\ exists[1] = TRUE
    /\ \A s \in Shards : exists[s] => (s = 1 \/ exists[s - 1])   \* no gap / acyclic prefix
    /\ chain <= Cardinality(ExistingShards)                       \* count bumped only after link

\* NoShardLost (temporal): while the run is live (holds its flock) a linked
\* shard is NEVER unlinked — the 61 GiB failure in miniature is a lost/leaked
\* shard. Producers only ever set exists TRUE; the reaper clears it solely when
\* ~flockHeld, so exists is monotone for a live run.
NoShardLost ==
    [][ \A s \in Shards : (exists[s] /\ flockHeld) => exists'[s] ]_vars

\* ReaperNeverReapsLiveRun: no shard is GC'd while the run holds its flock.
ReaperNeverReapsLiveRun == flockHeld => (reaped = FALSE)

\* --- probe-run completeness -----------------------------------------------
\* The distance from `h` to the FIRST EMPTY slot at or after it (Cap if the
\* table is full) — exactly where a linear-probe walk stops.
FirstEmptyFrom(s, h) ==
    IF \E j \in 0..(Cap-1) : slot[s][(h + j) % Cap] = 0
    THEN CHOOSE j \in 0..(Cap-1) :
            /\ slot[s][(h + j) % Cap] = 0
            /\ \A m \in 0..(j-1) : slot[s][(h + m) % Cap] # 0
    ELSE Cap

\* The elements a walk from `h` yields: the run, and nothing past it.
RunFrom(s, h) == { slot[s][(h + j) % Cap] : j \in 0..(FirstEmptyFrom(s, h) - 1) }

\* ProbeRunComplete: every element published in a shard is reachable from ITS OWN
\* home slot by walking to the first empty slot. There is no stored chain and no
\* pointer update — the run IS the enumeration — so this is the invariant that
\* makes an enumeration possible at all. It holds because a claim only ever turns
\* an empty slot non-empty (nothing is ever deleted), so a run is never punctured
\* and a walk can neither stop early nor skip a present element.
\*
\* This is the identity-key instance of the property; `shm_gset_keyed` checks the
\* general one, where a whole SET of elements shares one home slot.
ProbeRunComplete ==
    \A s \in ExistingShards :
      \A i \in 0..(Cap-1) :
        (slot[s][i] # 0) => (slot[s][i] \in RunFrom(s, Home[slot[s][i]]))

\* CannotSaturate: with the chosen bounds, growth never hits the MaxShards wall
\* (so the union invariants are exercised on the real grow path, not masked by a
\* saturation early-out). If TLC reports this violated, raise MaxShards.
CannotSaturate == saturated = FALSE

TypeOK ==
    /\ chain \in 1..MaxShards
    /\ committed \subseteq Elements
    /\ \A s \in Shards : occ[s] \in 0..Cap

--------------------------------------------------------------------------------
\* Liveness: every intended element eventually appears in the reader's union and
\* stays there (grow-only => monotone, so <> suffices).
EventuallyComplete == <>(ReaderUnion = IntendedAll)

================================================================================
