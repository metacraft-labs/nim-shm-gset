------------------------------ MODULE shm_gset_pool ------------------------------
(***************************************************************************)
(* TLA+ model of the HOST-SIDE RECYCLING POOL (HM-3), `src/shm_gset/pool.nim`.*)
(*                                                                          *)
(* WHY THIS EXISTS, and what it is NOT. The pool adds no new SHARED-MEMORY  *)
(* protocol: the only segment operations it performs are `createSet`,       *)
(* `reset`, `markConsumerGone` and `detach`, every one of them already      *)
(* modelled by `shm_gset_reset.tla` and already checked under weak memory by *)
(* `../core/shm_gset_reset_core.c` and `../litmus/`. What the pool DOES add  *)
(* is a new CONCURRENT LIFECYCLE around them — acquire / reset / lease /     *)
(* release / retire, driven by N in-flight actions inside one process — and  *)
(* that lifecycle has its own safety properties which no existing artifact   *)
(* states. Those are what this module checks. TLC (sequentially consistent   *)
(* interleavings) is the right tool for it precisely because the lifecycle   *)
(* is mutex-guarded and intra-process; the weak-memory tier below it is      *)
(* unchanged and un-weakened.                                               *)
(*                                                                          *)
(* WHAT IS MODELLED                                                         *)
(*   * a bounded set of chains, each `absent` -> `leased`/`idle` -> ...      *)
(*     -> `retired`, with a per-chain GENERATION that only `reset` moves;    *)
(*   * acquire: take an idle chain, reset it, and hand out a lease ONLY when *)
(*     the generation advanced past the value the pool was holding — the     *)
(*     "confirmed reset" the implementation performs;                        *)
(*   * the three refusal classes `reset` distinguishes, with the policy the  *)
(*     pool applies to each: BUSY (transient, retried up to a budget, then   *)
(*     retired), UNTRACKED and GENERATION-EXHAUSTED (retired at once);       *)
(*   * release: end the action, record the generation, return the chain.     *)
(*                                                                          *)
(* DELIBERATE ABSTRACTIONS, stated so the model is not read as proving more  *)
(* than it does:                                                            *)
(*   * the idle list is a SET, not a queue. WHICH idle chain an acquire      *)
(*     picks is irrelevant to every invariant here; the FIFO rotation in the *)
(*     implementation only decides WHEN a refused chain is retried, which is *)
(*     a quality-of-service property, not a safety one.                      *)
(*   * `maxIdle` (the bound on how many warm chains are kept) is omitted: it *)
(*     only ever retires MORE chains, which cannot make any invariant here   *)
(*     false.                                                               *)
(*   * a producer of the finished action that is still attached is modelled  *)
(*     as the boolean `cbusy`, and the untracked-overflow case as            *)
(*     `cuntracked`. WHY the chain refuses is `shm_gset_reset.tla`'s job;    *)
(*     THIS module is about what the pool does with the answer.              *)
(*                                                                          *)
(* WHAT IS *NOT* MODELLED, AND HAS ALREADY COST A REGRESSION. This module has *)
(* exactly ONE process in it. There is no second process, no `fork`, and no    *)
(* `destroySetPool` — the shutdown half here is `close` and `retire` only. So  *)
(* the pool's OWNERSHIP rule (a pooled chain belongs to the process that       *)
(* CREATED it, and `acquire` / `release` / `close` / `destroySetPool` all      *)
(* refuse from any other process) is outside this model's scope entirely and   *)
(* cannot be checked here. That is not hypothetical: in the round where the    *)
(* `created` sweep moved into `destroySetPool` without its `getpid()` guard, a *)
(* fork child unlinked its PARENT's live chain, and TLC stayed green the whole *)
(* time because nothing here could go red. The only guards on that rule are    *)
(* the two Nim fork tests in `tests/test_shm_gset_pool.nim`. IF THE GUARD LIST *)
(* IN pool.nim GROWS, THE TEST LIST MUST GROW WITH IT — this model will not    *)
(* notice.                                                                    *)
(*                                                                          *)
(* THE THREE TEETH. Each mechanism can be switched off from this same module *)
(* so the resulting violation can be observed rather than asserted:          *)
(*   ResetOnAcquire    = FALSE -> NeverUnresetHandout violated               *)
(*   ExclusiveIdle     = FALSE -> NoSharedChain + LeaseGenStable violated    *)
(*   RetireOnPermanent = FALSE -> NoPermanentlyIdleChain violated            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Chains,            \* the chains the pool may ever create
    Workers,           \* concurrent in-flight actions
    Rounds,            \* actions each worker performs
    MaxGen,            \* generation bound: a chain at MaxGen cannot be reset
    BusyBudget,        \* consecutive rsBusyProducers refusals before retiring
    ResetOnAcquire,    \* TRUE == acquire resets before handing out (shipped)
    ExclusiveIdle,     \* TRUE == a leased chain leaves the idle set (shipped)
    RetireOnPermanent  \* TRUE == untracked / exhausted retire at once (shipped)

ASSUME Rounds \in Nat /\ Rounds >= 1
ASSUME MaxGen \in Nat /\ MaxGen >= 2
ASSUME BusyBudget \in Nat /\ BusyBudget >= 1

VARIABLES
    cstate,      \* [Chains -> {"absent","idle","leased","retired"}]
    cgen,        \* [Chains -> Nat] : generation; only `reset`/create moves it
    lastRel,     \* [Chains -> Nat] : generation when the POOL last held it
    crefusals,   \* [Chains -> Nat] : consecutive rsBusyProducers
    cbusy,       \* [Chains -> BOOLEAN] : a producer of the last action lives
    cuntracked,  \* [Chains -> BOOLEAN] : a producer the registry could not track
    csawPerm,    \* [Chains -> BOOLEAN] : the pool has OFFERED this chain and
                 \* seen a PERMANENT refusal (untracked / exhausted). It is
                 \* not "was offered": a chain can be offered while it is
                 \* merely BUSY and only become permanently unrecyclable
                 \* afterwards, and the pool cannot be held to a decision it
                 \* had no way to make yet.
    wstate,      \* [Workers -> {"idle","holding"}]
    wchain,      \* [Workers -> Chains \cup {NoChain}]
    wgen,        \* [Workers -> Nat] : the generation handed to this worker
    wrounds      \* [Workers -> Nat] : actions completed

CONSTANT NoChain
ASSUME NoChain \notin Chains

vars == << cstate, cgen, lastRel, crefusals, cbusy, cuntracked, csawPerm,
           wstate, wchain, wgen, wrounds >>

Init ==
    /\ cstate     = [c \in Chains |-> "absent"]
    /\ cgen       = [c \in Chains |-> 0]
    /\ lastRel    = [c \in Chains |-> 0]
    /\ crefusals  = [c \in Chains |-> 0]
    /\ cbusy      = [c \in Chains |-> FALSE]
    /\ cuntracked = [c \in Chains |-> FALSE]
    /\ csawPerm   = [c \in Chains |-> FALSE]
    /\ wstate     = [w \in Workers |-> "idle"]
    /\ wchain     = [w \in Workers |-> NoChain]
    /\ wgen       = [w \in Workers |-> 0]
    /\ wrounds    = [w \in Workers |-> 0]

\* The three refusal classes, exactly as `reset` distinguishes them.
BusyRefusal(c)      == cbusy[c]
UntrackedRefusal(c) == ~cbusy[c] /\ cuntracked[c]
ExhaustedRefusal(c) == ~cbusy[c] /\ ~cuntracked[c] /\ cgen[c] >= MaxGen
PermanentRefusal(c) == UntrackedRefusal(c) \/ ExhaustedRefusal(c)
AnyRefusal(c)       == BusyRefusal(c) \/ PermanentRefusal(c)

Recyclable(c) == cstate[c] = "idle" /\ ~AnyRefusal(c)
NoUsableIdle  == \A c \in Chains : cstate[c] = "idle" => AnyRefusal(c)
WantsWork(w)  == wstate[w] = "idle" /\ wrounds[w] < Rounds

(*************************************************************************)
(* ACQUIRE — the recycling path.                                         *)
(*                                                                       *)
(* The generation is bumped and the lease is cut in ONE step, which is    *)
(* faithful: the chain is out of the idle list and not yet in a lease for *)
(* the whole of `reset`, so no other worker can observe the intermediate  *)
(* state. What `reset` itself does in that window is the subject of       *)
(* shm_gset_reset.tla, not of this module.                               *)
(*************************************************************************)
WAcquireIdle(w, c) ==
    /\ WantsWork(w)
    /\ Recyclable(c)
    /\ LET ng == IF ResetOnAcquire THEN cgen[c] + 1 ELSE cgen[c] IN
         /\ cgen'      = [cgen EXCEPT ![c] = ng]
         /\ wgen'      = [wgen EXCEPT ![w] = ng]
    /\ cstate'    = IF ExclusiveIdle THEN [cstate EXCEPT ![c] = "leased"]
                                     ELSE cstate
    /\ crefusals' = [crefusals EXCEPT ![c] = 0]
    /\ csawPerm'  = [csawPerm EXCEPT ![c] = FALSE]
    /\ wstate'    = [wstate EXCEPT ![w] = "holding"]
    /\ wchain'    = [wchain EXCEPT ![w] = c]
    /\ UNCHANGED << lastRel, cbusy, cuntracked, wrounds >>

\* rsBusyProducers: TRANSIENT. Count it and put the chain back; retire only
\* when the budget is exhausted, because a producer that never exits (the §4.1
\* detached-descendant shape) would otherwise wedge the pool on this chain.
WRefuseBusy(w, c) ==
    /\ WantsWork(w)
    /\ cstate[c] = "idle"
    /\ BusyRefusal(c)
    /\ crefusals' = [crefusals EXCEPT ![c] = crefusals[c] + 1]
    /\ csawPerm'  = [csawPerm EXCEPT ![c] = FALSE]
    /\ cstate'    = IF crefusals[c] + 1 >= BusyBudget
                      THEN [cstate EXCEPT ![c] = "retired"]
                      ELSE cstate
    /\ UNCHANGED << cgen, lastRel, cbusy, cuntracked, wstate, wchain, wgen,
                    wrounds >>

\* rsProducersUntracked / rsGenerationExhausted: may be PERMANENT. Retire.
\* With RetireOnPermanent = FALSE the chain is merely put back, which is the
\* mutation: it then sits in the idle set forever, warm, mapped and useless.
WRefusePermanent(w, c) ==
    /\ WantsWork(w)
    /\ cstate[c] = "idle"
    /\ PermanentRefusal(c)
    /\ csawPerm'  = [csawPerm EXCEPT ![c] = TRUE]
    /\ cstate'    = IF RetireOnPermanent
                      THEN [cstate EXCEPT ![c] = "retired"]
                      ELSE cstate
    /\ crefusals' = [crefusals EXCEPT ![c] = crefusals[c]]
    /\ UNCHANGED << cgen, lastRel, cbusy, cuntracked, wstate, wchain, wgen,
                    wrounds >>

\* Phase 2 of acquire: no idle chain is usable, so create one. Generation 1 and
\* empty by construction, which is the base case of NeverUnresetHandout.
WCreate(w, c) ==
    /\ WantsWork(w)
    /\ NoUsableIdle
    /\ cstate[c] = "absent"
    /\ cstate'    = [cstate EXCEPT ![c] = "leased"]
    /\ cgen'      = [cgen EXCEPT ![c] = 1]
    /\ lastRel'   = [lastRel EXCEPT ![c] = 0]
    /\ csawPerm'  = [csawPerm EXCEPT ![c] = FALSE]
    /\ wstate'    = [wstate EXCEPT ![w] = "holding"]
    /\ wchain'    = [wchain EXCEPT ![w] = c]
    /\ wgen'      = [wgen EXCEPT ![w] = 1]
    /\ UNCHANGED << crefusals, cbusy, cuntracked, wrounds >>

(*************************************************************************)
(* RELEASE — end the action, record the generation, return the chain.    *)
(*                                                                       *)
(* Whether a producer of the finished action is still attached, and       *)
(* whether one of them was untrackable, is decided nondeterministically   *)
(* here: that is exactly what the pool cannot know and must ask `reset`   *)
(* about at the next acquire.                                            *)
(*************************************************************************)
WRelease(w) ==
    /\ wstate[w] = "holding"
    /\ \E b \in BOOLEAN : \E u \in BOOLEAN :
         /\ cbusy'      = [cbusy EXCEPT ![wchain[w]] = b]
         /\ cuntracked' = [cuntracked EXCEPT ![wchain[w]] = cuntracked[wchain[w]] \/ u]
    /\ cstate'    = [cstate EXCEPT ![wchain[w]] = "idle"]
    /\ lastRel'   = [lastRel EXCEPT ![wchain[w]] = cgen[wchain[w]]]
    /\ csawPerm'  = [csawPerm EXCEPT ![wchain[w]] = FALSE]
    /\ wstate'    = [wstate EXCEPT ![w] = "idle"]
    /\ wchain'    = [wchain EXCEPT ![w] = NoChain]
    /\ wrounds'   = [wrounds EXCEPT ![w] = wrounds[w] + 1]
    /\ UNCHANGED << cgen, crefusals, wgen >>

\* The straggling producer finally exits, so a busy chain becomes recyclable
\* again. Weakly fair: the ORDINARY case really does clear.
ProducerExits(c) ==
    /\ cbusy[c]
    /\ cbusy' = [cbusy EXCEPT ![c] = FALSE]
    /\ UNCHANGED << cstate, cgen, lastRel, crefusals, cuntracked, csawPerm,
                    wstate, wchain, wgen, wrounds >>

\* A retired chain's files are UNLINKED and its identity is gone, so the slot it
\* occupied in this model may stand for a chain the pool creates later. `Chains`
\* is therefore a bound on CONCURRENT chains, not on chains over time — which is
\* what the implementation does (nothing bounds how many chains a pool may
\* create in its life; `maxIdle` bounds only how many it keeps WARM). Without
\* this the model would report a spurious liveness failure the moment every slot
\* had been retired once, which is an artifact of the bound and not a property
\* of the pool.
SlotReclaimed(c) ==
    /\ cstate[c] = "retired"
    /\ cstate'     = [cstate EXCEPT ![c] = "absent"]
    /\ cgen'       = [cgen EXCEPT ![c] = 0]
    /\ lastRel'    = [lastRel EXCEPT ![c] = 0]
    /\ crefusals'  = [crefusals EXCEPT ![c] = 0]
    /\ cbusy'      = [cbusy EXCEPT ![c] = FALSE]
    /\ cuntracked' = [cuntracked EXCEPT ![c] = FALSE]
    /\ csawPerm'   = [csawPerm EXCEPT ![c] = FALSE]
    /\ UNCHANGED << wstate, wchain, wgen, wrounds >>

Next ==
    \/ \E w \in Workers : \E c \in Chains :
         WAcquireIdle(w, c) \/ WRefuseBusy(w, c) \/ WRefusePermanent(w, c)
           \/ WCreate(w, c)
    \/ \E w \in Workers : WRelease(w)
    \/ \E c \in Chains : ProducerExits(c) \/ SlotReclaimed(c)

WSteps(w) == \/ \E c \in Chains : WAcquireIdle(w, c) \/ WCreate(w, c)
                                    \/ WRefuseBusy(w, c) \/ WRefusePermanent(w, c)
             \/ WRelease(w)

Spec == Init /\ [][Next]_vars
             /\ (\A w \in Workers : WF_vars(WSteps(w)))
             /\ (\A c \in Chains : WF_vars(ProducerExits(c)))
             /\ (\A c \in Chains : WF_vars(SlotReclaimed(c)))

(*************************************************************************)
(* INVARIANTS                                                            *)
(*************************************************************************)
TypeOK ==
    /\ cstate \in [Chains -> {"absent", "idle", "leased", "retired"}]
    /\ cgen \in [Chains -> 0..MaxGen]
    /\ wstate \in [Workers -> {"idle", "holding"}]
    /\ wchain \in [Workers -> Chains \cup {NoChain}]

\* SAFETY 1 — NO TWO IN-FLIGHT ACTIONS SHARE A CHAIN.
\* If this fails, two actions write into one segment and BOTH dependency sets
\* are wrong. In the implementation it is unrepresentable rather than merely
\* forbidden: `acquire` MOVES the SetHost out of the idle list, so while a chain
\* is leased the pool holds no handle to it at all.
NoSharedChain ==
    \A w1 \in Workers : \A w2 \in Workers :
        (w1 # w2 /\ wstate[w1] = "holding" /\ wstate[w2] = "holding")
            => wchain[w1] # wchain[w2]

\* SAFETY 2 — A CALLER CAN NEVER ACQUIRE A CHAIN THAT WAS NOT RESET.
\* The generation handed to a worker strictly exceeds the one the chain carried
\* while the POOL was holding it. `reset` is the only thing that moves the
\* generation, so this IS "it was reset", stated as an observable rather than as
\* a trusted call. A newly created chain satisfies it as the base case
\* (lastRel = 0, wgen = 1) because it is empty by construction.
NeverUnresetHandout ==
    \A w \in Workers :
        wstate[w] = "holding" => wgen[w] > lastRel[wchain[w]]

\* SAFETY 3 — A LEASED CHAIN IS NEVER RECYCLED UNDER ITS HOLDER.
\* The other half of exclusivity: not merely "two workers do not hold it", but
\* "nobody resets it while one worker does". A reset under a live action would
\* make every element that action has already published unreachable — silent
\* evidence loss rather than cross-attribution, but just as wrong.
LeaseGenStable ==
    \A w \in Workers :
        wstate[w] = "holding" => cgen[wchain[w]] = wgen[w]

\* SAFETY 4 — RETIREMENT IS FINAL.
\* A retired chain's files are unlinked, so handing it out again would be a
\* lease over a segment that no longer has a name on disk.
RetiredIsNeverHeld ==
    \A w \in Workers :
        wstate[w] = "holding" => cstate[wchain[w]] # "retired"

\* SAFETY 5 — CHAIN ACCOUNTING: nothing is lost track of.
\* Every chain is in exactly one place, and a leased chain is held by exactly
\* one worker. A chain that is "leased" with no holder is a leaked segment: a
\* mapped chain nobody can return, nobody can retire, and the reaper will not
\* collect while the pool's process lives.
Holders(c) == { w \in Workers : wstate[w] = "holding" /\ wchain[w] = c }
ChainAccounting ==
    \A c \in Chains :
        /\ (cstate[c] = "leased") => Cardinality(Holders(c)) = 1
        /\ (cstate[c] \in {"absent", "retired"}) => Holders(c) = {}

\* SAFETY 6 — A PERMANENTLY UNRECYCLABLE CHAIN IS RETIRED, NOT KEPT.
\* `rsProducersUntracked` and `rsGenerationExhausted` can never clear on their
\* own, so a pool that retried them would keep a warm, mapped, useless chain for
\* the life of the host — and would look merely "busy" while doing it.
NoPermanentlyIdleChain ==
    \A c \in Chains :
        (cstate[c] = "idle" /\ csawPerm[c]) => ~PermanentRefusal(c)

\* SAFETY 7 — the retry budget is a BOUND, not an aspiration.
BusyRetriesBounded ==
    \A c \in Chains : crefusals[c] <= BusyBudget

\* LIVENESS — every action eventually runs and gives its chain back, even
\* though chains refuse, get retired, and have to be replaced.
EventuallyAllServed ==
    <>[](\A w \in Workers : wrounds[w] = Rounds /\ wstate[w] = "idle")
================================================================================
