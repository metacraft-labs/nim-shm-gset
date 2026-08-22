------------------------ MODULE shm_gset_pool_probes ------------------------
(* VACUITY + TEETH probes for `shm_gset_pool`. Not part of the shipped        *)
(* configuration: this module exists so a reviewer can re-derive, rather than *)
(* take on faith, that the green run in `shm_gset_pool_MC` is not green       *)
(* because the model never reaches the interesting states.                    *)
(*                                                                            *)
(* Each probe asserts the NEGATION of a behaviour the model must reach. Add    *)
(* one to the INVARIANTS section of a copy of `shm_gset_pool_MC.cfg`, point    *)
(* TLC at THIS module instead, and confirm TLC reports it VIOLATED:            *)
(*                                                                            *)
(*   sed 's/^INVARIANTS/INVARIANTS\n    NoConcurrentLeasesProbe/' \            *)
(*     shm_gset_pool_MC.cfg > /tmp/probe.cfg                                   *)
(*   tlc -workers 4 -config /tmp/probe.cfg shm_gset_pool_probes.tla            *)
(*                                                                            *)
(* Results at the time of writing, all against the SHIPPED configuration:      *)
(*                                                                            *)
(*   NoConcurrentLeasesProbe   VIOLATED  two leases really are in flight at    *)
(*                                       once, so NoSharedChain is not         *)
(*                                       vacuously true                        *)
(*   NoRecycleProbe            VIOLATED  a chain really is recycled            *)
(*   NoTwoRecyclesProbe        VIOLATED  ...more than once                     *)
(*   NoRetireProbe             VIOLATED  a chain really is retired             *)
(*   NoBusyRetireProbe         VIOLATED  the BUSY budget really is exhausted,  *)
(*                                       so that policy branch is exercised    *)
(*   NoPermanentRefusalProbe   VIOLATED  a PERMANENT refusal really is seen,   *)
(*                                       so NoPermanentlyIdleChain is not      *)
(*                                       vacuously true                        *)
(*   NoReleaseProbe            VIOLATED  actions really end and hand back      *)
(*                                                                            *)
(* And the teeth, run from `shm_gset_pool_MC.cfg` itself by flipping ONE       *)
(* constant to FALSE (no probe needed — the shipped invariants catch them):    *)
(*                                                                            *)
(*   ResetOnAcquire    = FALSE  ->  NeverUnresetHandout violated               *)
(*   ExclusiveIdle     = FALSE  ->  NoSharedChain violated (and, with          *)
(*                                  NoSharedChain removed, LeaseGenStable too) *)
(*   RetireOnPermanent = FALSE  ->  NoPermanentlyIdleChain violated            *)
EXTENDS shm_gset_pool

CONSTANTS ca, cb, nochain

ChainsDef  == {ca, cb}
WorkersDef == {"wa", "wb"}

NoConcurrentLeasesProbe ==
    ~(\E w1 \in Workers : \E w2 \in Workers :
        w1 # w2 /\ wstate[w1] = "holding" /\ wstate[w2] = "holding")

NoRecycleProbe          == \A c \in Chains : cgen[c] <= 1
NoTwoRecyclesProbe      == \A c \in Chains : cgen[c] <= 2
NoRetireProbe           == \A c \in Chains : cstate[c] # "retired"
NoBusyRetireProbe       == \A c \in Chains : crefusals[c] < BusyBudget
NoPermanentRefusalProbe == \A c \in Chains : ~csawPerm[c]
NoReleaseProbe          == \A w \in Workers : wrounds[w] = 0
==============================================================================
