## HOST-SIDE RECYCLING POOL (HM-3) — hand an already-grown chain to the next
## action instead of calling `createSet`.
##
## `reset` (HM-2) makes recycling POSSIBLE; this makes it HAPPEN. A long-lived
## host — the build engine once it hosts the monitor in-process — asks the pool
## for a chain per action and gives it back when the action ends. The first
## action pays to grow the shards; every later action inherits that capacity, so
## grow-only becomes an amortisation rather than a per-action cost.
##
## ===========================================================================
## THE POOL OWNS RESET, AND THAT IS STRUCTURAL
## ===========================================================================
##
## The milestone's requirement is that *a caller must not be able to acquire a
## chain that was not reset*, and that this be a property of the shapes rather
## than of a comment. Four things make it one:
##
## 1. `SetLease` has NO public constructor. Its fields are private to this
##    module, so `SetLease(host: ...)` does not compile outside it, and the only
##    proc that produces a LIVE one is `acquire`.
## 2. `acquire` has exactly two paths to a live lease. The recycling path cuts
##    one only when `reset` returned `rsReset`; the other path CREATES a chain,
##    which is empty by construction. There is no third.
##
##    The recycling path ALSO re-reads the chain's generation out of the shared
##    header and requires it to have advanced past the value the pool was
##    holding. Be precise about what that check is worth: it is
##    DEFENCE-IN-DEPTH, not the guarantee. `reset` returns `rsReset` only after
##    it has published `generation = cur + 1` as its commit store
##    (`shm_gset.reset`, the `storeU64Release(b, ShOffGeneration, next)` at the
##    end), so `rsReset` already IMPLIES the bump and the extra comparison is
##    redundant by construction — deleting it reddens no test, and that is
##    expected rather than a gap. What it buys is that the pool's hand-out
##    condition is stated over the SEGMENT's own published state rather than
##    over a return value: if some future change ever made `rsReset` reachable
##    without a commit, or a chain's header were clobbered under the pool, the
##    pool would refuse instead of handing the chain out. The load-bearing
##    guarantee is `rsReset`; this is the belt to its braces.
## 3. `reset` is not reachable through a lease. A lease exposes the action's
##    read surface (`items`, `snapshot`, `shardCount`, `growthFailures`, ...)
##    and nothing that recycles, ends or tears down the chain. Those belong to
##    `release` / `retire`, which are the pool's.
## 4. While a chain is leased the pool holds NO handle to it — `acquire` MOVES
##    the `SetHost` out of the idle list and `release` moves it back. Two leases
##    over one chain is therefore not a race to be won but a state that cannot
##    be represented.
##
## ===========================================================================
## WHO OWNS A POOLED CHAIN (the reaper hazard, decided rather than inherited)
## ===========================================================================
##
## HM-2 recorded a hazard for whoever built this: `reset` re-points
## `ShOffConsumerPid` / `ShOffConsumerBoot` at the CALLING process, so a pool
## that resets from a different process than the one keeping the chain mapped
## "hands the reaper an owner pid that may exit first".
##
## The hazard is real; the stated mechanism is not. `ShOffConsumerPid` and
## `ShOffConsumerBoot` are WRITE-ONLY in this library — written by `createSetT`
## and by `reset`, read by nothing, here or in io-mon. The reaper's staleness
## rule (`reapStaleSegmentsDetailed`) takes its owner pid from the shard file's
## NAME (`{appId}~{chainSeq}.{boot}.{pid}`), which `reset` deliberately never
## touches, because not renaming is the whole point of moving the run identity
## into the header. So reset's re-pointing has no effect on the reaper at all.
##
## What DOES decide a pooled chain's fate is the pid baked into its name at
## CREATE time, and that one cannot be re-stamped. Hence the rule this pool
## implements:
##
##   **A pooled chain is owned, for its entire life, by the process that
##   created it — which is always the pool's own process.**
##
## - The pool creates every chain it manages (`startHost`); it never adopts a
##   foreign `SetHost`. So the name-borne owner pid — the only owner identity
##   anything actually consults — is the pool's pid from creation to unlink.
## - The pool is NOT fork-inheritable. `acquire`, `release`, `close` and
##   `destroySetPool` — EVERY entry point that mutates anything — check
##   `getpid()` against the pid that created the pool and refuse from any other
##   process. There are FOUR of them, not three: `destroySetPool` was for one
##   round the only unguarded one, and being the entry point that UNLINKS
##   unconditionally that made it the most destructive call in the module. The
##   list is written out in full here so a fifth cannot be added without
##   noticing. Each refuses in a DIFFERENT way, because each has a different
##   channel to report on and a caller has to know which:
##
##   | proc | refusal from a foreign process |
##   |---|---|
##   | `acquire` | returns a dead lease; `available` is false and `refusal` is `prForeignProcess`. The only one that names the reason. |
##   | `release` | SILENT no-op. It returns `void` and `SetLease` carries no error channel, so there is nowhere to report; the lease is marked spent and the chain is left entirely alone. A child cannot learn from the call that it did nothing. |
##   | `close`   | returns `-1` (distinct from the 0-or-more outstanding-lease count it returns in the owning process) and unlinks nothing. |
##   | `destroySetPool` | does NOTHING — no `close`, no sweep, no unlink, no `deinitLock`, no free — and LEAVES `p` NON-NIL. That is the channel: after a destroy in the OWNING process `p` is nil, so `p != nil` after the call is exactly "this process was refused". A child may not free even its own COW copy; see the proc's doc comment for why that was decided rather than allowed. |
##
##   All four guards are placed BEFORE the first `withLock`, deliberately. A
##   `fork()` from a multi-threaded host — which is the shape this pool is built
##   for — can copy the pool's mutex in a LOCKED state if another thread held it
##   at the instant of the fork, so a child that reached a `withLock` at all
##   would deadlock on a lock nobody will ever release.
##
##   READ THAT PRECISELY, because it is a statement about the four MUTATING
##   entry points and not about the module. Three exported procs are unguarded
##   and DO take the lock: `stats`, `idleChains` and `leasedChains`. They mutate
##   nothing and unlink nothing, so they are outside the ownership rule — but
##   they are inside the deadlock hazard, and a fork child that calls one of
##   them can block forever on a mutex copied in the locked state. That is
##   recorded rather than fixed: guarding them would mean inventing a return
##   value for "you are not the owner" on three procs whose types have no room
##   for one (`0` is a legitimate idle count), and a child inspecting a pool it
##   is forbidden to use is already a caller error. If a fifth MUTATING entry
##   point is ever added it belongs in the table above; if one of these three
##   ever grows a write, it stops being an exception and needs a guard.
##
##   Refusing is not hygiene: a forked child holding
##   an inherited lease shares the parent's MAP_SHARED segment, so a child that
##   "released" it would `markConsumerGone` on a chain the PARENT is still
##   serving an action with, and every one of that action's producers would
##   start fast-failing with `emConsumerGone` — unmonitored, and silently. The
##   refusal is what makes reset's re-pointing of `ShOffConsumerPid` a provable
##   no-op for a pooled chain rather than merely a harmless one.
##   `destroySetPool` is WORSE than that, which is why it must be guarded most of
##   all: `emConsumerGone` is at least a status a producer can see, whereas an
##   unlinked anchor leaves the parent's producers unable to `attachProducer` at
##   all. Measured on the unguarded build, parent mid-action: `files=0`, anchor
##   gone, `attachProducer(...).available == false`. Both fork-child properties
##   are tested — `a_fork_child_cannot_touch_the_parents_pooled_chain` covers
##   `acquire`/`release`/`close`, `a_fork_child_cannot_destroy_the_parents_pool`
##   covers this one.
## - Consequence, stated so it is not discovered later: the reaper's verdict on
##   a pooled chain tracks the POOL's process, not any transient action's. A
##   chain outlives the actions that borrow it and dies with the host, which is
##   exactly the lifetime a long-lived monitor host wants.
##
## ===========================================================================
## WHAT THE POOL DOES WITH A REFUSAL
## ===========================================================================
##
## `reset` refuses in six ways and they are NOT interchangeable:
##
## | status                  | policy | why |
## |---|---|---|
## | `rsBusyProducers`       | RETRY, bounded, then retire | transient: it clears when those processes exit, and a dead producer's registry entry is reclaimed by the scan itself. But it is not GUARANTEED to clear — the §4.1 shape is a detached descendant that outlives its root and never exits — so an unbounded retry would wedge the pool on one chain. The refusal count is carried on the idle entry ACROSS acquires, so the retries are spread over real time rather than spun in a microsecond. |
## | `rsProducersUntracked`  | RETIRE | the chain never learned those pids, so if one died without detaching the count never falls again. It CAN clear (if they all detach cleanly), so retiring costs at most one chain's capacity — against a chain that quietly stops recycling forever. |
## | `rsGenerationExhausted` | RETIRE | permanent by construction. |
## | `rsUnavailable`         | RETIRE | the chain is not usable any more. |
## | `rsNotConsumer`         | RETIRE | unreachable (the pool only ever holds consumer handles); retired rather than ignored so an impossible state cannot become a silent hand-out. |
## | `rsInvalidRunId`        | REFUSE THE ACQUIRE, touch no chain | a CALLER error, not a chain fault. Retiring here would destroy a perfectly good chain for a bad argument, and a naive "anything but `rsReset` ⇒ retire" does exactly that. It is pre-validated, so the case is not reachable through `acquire` at all. |
##
## RETIRE UNLINKS THE SHARD FILES, and that is not optional. The reaper collects
## a chain only when its owner pid is DEAD, and the owner is the pool's process,
## which is alive by construction — so a retired chain that was merely unmapped
## would sit on disk for the whole life of the host. That is the 61 GiB failure
## in miniature. Unlinking is safe even for a chain retired while a producer is
## still attached: `release` marks the consumer gone before the chain ever
## becomes retirable, so `emit` fast-fails with `emConsumerGone` and no pooled
## chain can accept an insert (or therefore grow a new shard file) while it is
## condemned; a producer that still holds a mapping keeps a valid one by POSIX
## inode refcounting and reads bytes nobody will ever attribute to anything.
## (That "release marks the consumer gone first" premise is not taken on trust:
## `release_marks_the_consumer_gone_for_a_late_producer` asserts it against a
## real producer still attached across the release, including that the condemned
## chain cannot link a new shard file.)
##
## ===========================================================================
## SHUTDOWN, AND WHAT EACH HALF OF IT GUARANTEES
## ===========================================================================
##
## Two steps, and the split is deliberate:
##
## - `close` retires every IDLE chain, unlinks its files, and returns how many
##   leases are still OUTSTANDING. It does not unlink anything belonging to
##   those, because it cannot distinguish a lease an action is still writing to
##   from one that was dropped and never will come back — so a nonzero result
##   means "these files are still on disk, and you have leases to account for".
##   The pool stays callable after it: `acquire` answers `prClosed`.
## - `destroySetPool` frees the pool object, and is the host's statement that no
##   thread will touch the pool again. An outstanding chain is therefore
##   abandoned by definition at that point, so this is where the files of a
##   dropped lease are finally unlinked.
##
## The honest summary for a caller: RELEASE EVERY LEASE. A dropped one keeps its
## shard files for as long as the pool object lives, and `close` will keep
## telling you so.

import std/[locks, os, strutils]
import ../shm_gset
import ./transport

export transport.SetHost, transport.ResetStatus

type
  PoolRefusal* = enum
    ## Why `acquire` produced no chain. `prNone` on success.
    prNone
    prForeignProcess  ## called from a process that did not create this pool
                      ## (a fork child) — see the ownership section above
    prInvalidRunId    ## the runId does not fit `RunIdMaxBytes`; no chain was
                      ## touched, because this is a caller fault not a chain one
    prCreateFailed    ## no idle chain was recyclable and `createSet` failed
    prClosed          ## the pool has been closed

  RetireReason* = enum
    ## Why a chain left the pool for good. Counted per reason in `PoolStats`,
    ## because "the pool keeps retiring chains" and "the pool keeps retiring
    ## chains BECAUSE producers never detach" are different operational faults.
    rrBusyBudgetExhausted  ## `rsBusyProducers` `busyRetryBudget` times running
    rrProducersUntracked   ## `rsProducersUntracked`
    rrGenerationExhausted  ## `rsGenerationExhausted`
    rrUnavailable          ## `rsUnavailable` / `rsNotConsumer`
    rrIdleOverflow         ## released into a full idle list (`maxIdle`)
    rrPoolClosed           ## `close`

  PoolStats* = object
    ## Observable pool behaviour. `createdChains` versus `recycledAcquires` is
    ## the metric the whole milestone exists to move: after warmup every acquire
    ## should be a recycle and `createdChains` should stop rising.
    acquires*: int            ## leases handed out
    createdChains*: int       ## acquires that had to CREATE a chain
    recycledAcquires*: int    ## acquires satisfied by resetting an idle chain
    releases*: int            ## leases handed back
    busyRefusals*: int        ## `rsBusyProducers` seen (retries, not failures)
    retired*: array[RetireReason, int]

  PooledChain = object
    ## An idle chain. DIRTY: it still holds the previous action's bytes, and it
    ## is `reset` on the way OUT rather than on the way in, because reset takes
    ## the NEXT action's runId and that is only known at `acquire`.
    host: SetHost
    genAtRelease: uint64   ## the generation while the pool last held it; a
                           ## lease is only ever cut when the generation has
                           ## moved PAST this
    busyRefusals: int      ## consecutive `rsBusyProducers`, carried across
                           ## acquires so "retry" happens over real time

  SetPoolObj = object
    ## The pool's state. Reached only through `SetPool`, a raw `ptr` — NOT a
    ## `ref`, and that is deliberate and load-bearing rather than a style
    ## choice.
    ##
    ## Nim's ORC reference counts are ATOMIC only under `-d:gcAtomicArc`
    ## (`--mm:atomicArc`); see `system/arc.nim`, where every increment and
    ## decrement is guarded by `when defined(gcAtomicArc) and hasThreadSupport`.
    ## Under the ordinary `--mm:orc --threads:on` build that this repo, io-mon
    ## and reprobuild all use, handing a `ref` to several threads means racing
    ## increments on one counter — which frees a live object and crashes inside
    ## the runtime, a long way from the code that did it. That is not
    ## hypothetical here: an earlier `ref object` version of this pool passed
    ## every functional test and then SIGSEGV'd in `arc.nim`'s
    ## `isObjDisplayCheck`, in a LATER test than the threaded one — the classic
    ## shape of a corrupted refcount. INTERMITTENTLY: a minority of whole-file
    ## runs, and the sampled rate wandered between roughly one run in six and one
    ## in eight across the samples taken. That spread is not a specification and
    ## nothing should be built on it; it is the REASON the fix was settled with
    ## TSAN (races on this refcount versus none) rather than by counting clean
    ## runs, since no feasible number of clean runs settles an event at that
    ## frequency.
    ##
    ## A `ptr` is copied without touching any counter, so N host threads may
    ## share one pool under the plain build. The rule that keeps the rest safe
    ## is then simple and total: **every GC'd field of this object is read or
    ## written only with `lock` held**, so the reference-count traffic on the
    ## strings and seqs inside it is serialised too. `dir` and `appId` are
    ## COPIED into locals under the lock before use for exactly that reason.
    lock: Lock
    ownerPid: int
    dir, appId: string
    shard0Cap, shard0ArenaCap: int
    maxIdle: int
    busyRetryBudget: int
    idle: seq[PooledChain]
    leasedNow: int
    created: seq[string]   ## path0 of every chain this pool created and has not
                           ## yet unlinked. An entry is dropped by
                           ## `retireLocked`, so after `close` has retired the
                           ## idle list this holds exactly the chains that are
                           ## still OUT — a lease in flight, or a lease that was
                           ## dropped and will never come back. `close` must not
                           ## unlink those (it cannot tell the two apart);
                           ## `destroySetPool` sweeps them, because that call is
                           ## the host's statement that nothing will touch the
                           ## pool again — in the OWNING process only. This
                           ## sweep is the module's one UNCONDITIONAL unlink, so
                           ## it is owner-gated like everything else that
                           ## mutates.
    closed: bool
    stats: PoolStats

  SetPool* = ptr SetPoolObj
    ## A process-local pool of recyclable chains, shared by every host thread.
    ## Created with `newSetPool`, released with `destroySetPool`. See
    ## `SetPoolObj` for why this is a `ptr` and not a `ref`.

  SetLease* = object
    ## An action's exclusive borrow of one pooled chain.
    ##
    ## NOT COPYABLE, on purpose. A copied lease released twice would put one
    ## chain into the idle list twice, and the next two acquires would hand the
    ## same shards to two concurrent actions — the exact cross-attribution the
    ## chain generation exists to prevent, arrived at through bookkeeping. The
    ## `=copy` error makes that a compile error rather than a race.
    host: SetHost
    pool: SetPool
    genAtAcquire: uint64
    live: bool
    why: PoolRefusal

proc `=copy`*(dst: var SetLease; src: SetLease) {.error:
  "a SetLease is exclusive: move it, or acquire another one".}

# --- construction -----------------------------------------------------------

proc newSetPool*(dir: string; appId = "io-mon"; shard0Cap = 1024;
    shard0ArenaCap = 256 * 1024; maxIdle = 8;
    busyRetryBudget = 3): SetPool =
  ## A pool over `dir`, scoped to `appId` (which is what the cross-restart
  ## reaper uses to avoid touching another app's segments).
  ##
  ## `maxIdle` bounds how many grown chains are kept warm — the memory the
  ## amortisation costs. `busyRetryBudget` is how many consecutive
  ## `rsBusyProducers` refusals a chain may accumulate, across acquires, before
  ## it is retired instead of retried.
  ##
  ## The object is allocated with `allocShared0` rather than `new`, so passing
  ## the pool to another thread copies a pointer and touches no reference count
  ## — see `SetPoolObj`. Zeroed memory is a valid empty `string`/`seq` under
  ## ARC/ORC (both are a length plus a nil payload), so the field assignments
  ## below are ordinary copies into a well-formed destination.
  result = cast[SetPool](allocShared0(sizeof(SetPoolObj)))
  initLock(result.lock)
  result.ownerPid = getCurrentProcessId()
  result.dir = dir
  result.appId = appId
  result.shard0Cap = shard0Cap
  result.shard0ArenaCap = shard0ArenaCap
  result.maxIdle = max(maxIdle, 0)
  result.busyRetryBudget = max(busyRetryBudget, 1)

proc ownsThisProcess*(p: SetPool): bool =
  ## Whether the CALLING process is the one that created this pool. False in a
  ## fork child, where every pool operation refuses — see the ownership section
  ## in this module's header for why that is a correctness rule and not tidiness.
  p != nil and p.ownerPid == getCurrentProcessId()

# --- chain files ------------------------------------------------------------

proc chainFiles(path0: string): seq[string] =
  ## Every shard file of the chain anchored at `path0`, from `shard0` up to the
  ## first index that does not exist. Derived from the anchor rather than from a
  ## `chainCount` read, because a retired chain may already be unmapped and
  ## because a shard whose chain-count bump was lost to a producer crash is
  ## still a file on disk that must not be left behind.
  const anchor = ".shard0"
  if not path0.endsWith(anchor): return
  let prefix = path0[0 ..< path0.len - anchor.len] & ".shard"
  var k = 0
  while true:
    let p = prefix & $k
    if not fileExists(p): break
    result.add p
    inc k

proc unlinkChain(path0: string) =
  for f in chainFiles(path0):
    try: removeFile(f)
    except CatchableError: discard

# --- private: retire (caller holds the lock) --------------------------------

proc retireLocked(p: SetPool; pc: var PooledChain; why: RetireReason) =
  ## Unmap and UNLINK a chain the pool is giving up on. Runs with the pool lock
  ## held, and therefore does its `munmap` + `unlink` there: retirement is rare
  ## (a refused reset or a full idle list), the alternative is a chain that is
  ## momentarily in neither the idle list nor a lease — which is exactly the
  ## "leaked segment" state `ChainAccounting` forbids in the TLA+ model — and
  ## the cost is a handful of syscalls, not I/O proportional to anything.
  let path0 = pc.host.path0
  pc.host.finish()          # mark the consumer gone, then unmap
  unlinkChain(path0)        # ...and do NOT wait for a reaper that cannot fire
  inc p.stats.retired[why]
  var keep: seq[string]
  for c in p.created:
    if c != path0: keep.add c
  p.created = keep

# --- acquire ----------------------------------------------------------------

proc refusedLease(why: PoolRefusal): SetLease =
  result.live = false
  result.why = why

proc acquire*(p: SetPool; runId: string): SetLease =
  ## Borrow a chain for one action, stamped with `runId`.
  ##
  ## The chain handed back is EMPTY and carries `runId`: either it was recycled
  ## from the idle list by a `reset` this proc performed and that returned
  ## `rsReset` (double-checked against the segment's published generation, which
  ## is defence-in-depth rather than the guarantee — see the module header), or
  ## it was created fresh, in which case it is empty by construction. There is
  ## no third path, and there is no path a caller can take that skips the reset.
  ##
  ## Never blocks. If every idle chain refuses (`rsBusyProducers`), the refusal
  ## is recorded on that chain for a later acquire and this one creates a chain
  ## rather than waiting on a producer that may never exit.
  if p == nil: return refusedLease(prClosed)
  if not validRunId(runId): return refusedLease(prInvalidRunId)
  if not p.ownsThisProcess(): return refusedLease(prForeignProcess)

  # Phase 1 — try to recycle. The idle list is a QUEUE: `release` appends, and
  # this takes from the front, so every chain comes round again and a chain that
  # refused stays in rotation instead of sinking to the bottom of a stack and
  # never being retried (which would leave a permanently-busy chain warm,
  # mapped and useless for the life of the host). Bounded by the idle count
  # OBSERVED at entry, so a chain put back after a busy refusal is retried on a
  # LATER acquire — real time has passed and its producers may have exited —
  # rather than spun on inside this one.
  var attempts = 0
  var budget = 0
  withLock p.lock:
    if p.closed: return refusedLease(prClosed)
    budget = p.idle.len
  while attempts < budget:
    inc attempts
    var pc: PooledChain
    var have = false
    withLock p.lock:
      if p.closed: return refusedLease(prClosed)
      if p.idle.len > 0:
        pc = move(p.idle[0])
        p.idle.delete(0)
        have = true
    if not have: break
    # From here the chain belongs to nobody but this call: it is out of the idle
    # list and not yet in a lease, so `reset` runs without the lock held.
    let before = pc.host.generation
    let st = pc.host.reset(runId)
    if st == rsReset and pc.host.generation > before:
      # The only place a pooled chain becomes leasable. `rsReset` is the
      # guarantee — `reset` publishes the generation bump as its commit store
      # before returning it — and the `generation > before` re-read is
      # defence-in-depth over the segment's own published state, redundant by
      # construction today (see point 2 of this module's header).
      withLock p.lock:
        inc p.leasedNow
        inc p.stats.acquires
        inc p.stats.recycledAcquires
      result.host = move(pc.host)
      result.pool = p
      result.genAtAcquire = result.host.generation
      result.live = true
      result.why = prNone
      return
    if st == rsBusyProducers:
      inc pc.busyRefusals
      withLock p.lock:
        inc p.stats.busyRefusals
        if pc.busyRefusals >= p.busyRetryBudget or p.closed:
          p.retireLocked(pc, rrBusyBudgetExhausted)
        else:
          p.idle.add(move(pc))         # back of the queue; retried later
      continue
    # Every other outcome retires the chain. `rsReset` with a generation that
    # did NOT advance cannot happen, and is handled the same way for exactly
    # that reason: an impossible state must not become a silent hand-out.
    let why =
      case st
      of rsProducersUntracked: rrProducersUntracked
      of rsGenerationExhausted: rrGenerationExhausted
      else: rrUnavailable
    withLock p.lock:
      p.retireLocked(pc, why)

  # Phase 2 — no recyclable chain: create one. Generation 1, empty by
  # construction, owner pid = this pool's process.
  #
  # `dir` and `appId` are COPIED under the lock, not borrowed across it. They
  # are GC'd strings living in the shared pool object, and a copy is a
  # reference-count increment; doing that from N threads at once, with ORC's
  # non-atomic counters, is precisely the race `SetPoolObj` documents.
  var dir, appId: string
  var cap0, arena0: int
  withLock p.lock:
    dir = p.dir
    appId = p.appId
    cap0 = p.shard0Cap
    arena0 = p.shard0ArenaCap
  var h = startHost(dir, runId, appId, cap0, arena0)
  if not h.available:
    return refusedLease(prCreateFailed)
  withLock p.lock:
    inc p.leasedNow
    inc p.stats.acquires
    inc p.stats.createdChains
    p.created.add h.path0
  result.host = move(h)
  result.pool = p
  result.genAtAcquire = result.host.generation
  result.live = true
  result.why = prNone

# --- release ----------------------------------------------------------------

proc release*(l: var SetLease) =
  ## End the action and hand the chain back. The pool marks the consumer GONE
  ## here — that is what makes a late producer of the finished action fast-fail
  ## with `emConsumerGone` instead of writing into a chain the next action is
  ## about to be given — and re-arms it at the next `acquire`, as part of the
  ## reset. The chain is NOT reset here: reset stamps the run identity, and the
  ## next action's identity is not known yet.
  ##
  ## Idempotent, and a SILENT no-op in a fork child (see the ownership section):
  ## a child that "released" an inherited lease would `markConsumerGone` on the
  ## PARENT's live segment and silently unmonitor the parent's running action.
  ## Silent because there is nowhere to speak — `release` returns `void` and a
  ## `SetLease` has no error channel — so unlike `acquire` (`prForeignProcess`),
  ## `close` (`-1`) and `destroySetPool` (leaves `p` non-nil), a child cannot
  ## learn from the call that it did nothing. `release` is the ONLY one of the
  ## four with no channel at all. The lease is still marked spent, so the child
  ## cannot retry.
  ##
  ## A lease that is DROPPED rather than released is not covered by any of this:
  ## nothing decrements `leasedNow`, so the chain stays "outstanding" forever,
  ## its consumer is never marked gone, and its shard files survive `close`
  ## (which then returns nonzero) until `destroySetPool` sweeps them.
  if not l.live: return
  l.live = false
  let p = l.pool
  l.pool = nil
  if p == nil: return
  if not p.ownsThisProcess(): return       # inherited by a fork child: drop it
  l.host.markConsumerGone()
  var pc = PooledChain(genAtRelease: l.host.generation, busyRefusals: 0)
  pc.host = move(l.host)
  withLock p.lock:
    inc p.stats.releases
    dec p.leasedNow
    if p.closed:
      p.retireLocked(pc, rrPoolClosed)
    elif p.idle.len >= p.maxIdle:
      p.retireLocked(pc, rrIdleOverflow)
    else:
      p.idle.add(move(pc))

# --- lease read surface -----------------------------------------------------
#
# Deliberately partial: everything an ACTION needs to read its evidence, and
# nothing that recycles, ends or tears down the chain. `reset`, `finish` and
# `markConsumerGone` are the pool's, which is what "the pool owns reset" means
# in the type system rather than in a comment.

proc available*(l: SetLease): bool = l.live
proc refusal*(l: SetLease): PoolRefusal = l.why
proc path0*(l: SetLease): string =
  ## The well-known shard0 path to hand producers via `REPRO_MONITOR_DEP_SHM`.
  if l.live: l.host.path0 else: ""
proc runId*(l: SetLease): string =
  if l.live: l.host.runId else: ""
proc generation*(l: SetLease): uint64 =
  if l.live: l.host.generation else: 0'u64
proc generationAtAcquire*(l: SetLease): uint64 = l.genAtAcquire
proc attachedProducers*(l: SetLease): int =
  if l.live: l.host.attachedProducers else: 0
proc untrackedProducers*(l: SetLease): int =
  if l.live: l.host.untrackedProducers else: 0
proc producerAttaches*(l: SetLease): uint64 =
  if l.live: l.host.producerAttaches else: 0'u64

iterator items*(l: var SetLease): seq[byte] =
  if l.live:
    for e in l.host.items: yield e

proc snapshot*(l: var SetLease): seq[seq[byte]] =
  if l.live: l.host.snapshot() else: @[]
proc shardCount*(l: var SetLease): int =
  if l.live: l.host.shardCount() else: 0
proc claimedSlots*(l: var SetLease): uint64 =
  if l.live: l.host.claimedSlots() else: 0'u64
proc growthFailures*(l: var SetLease): uint64 =
  if l.live: l.host.growthFailures() else: 0'u64

# --- inspection / shutdown --------------------------------------------------

proc stats*(p: SetPool): PoolStats =
  if p == nil: return
  withLock p.lock: result = p.stats

proc idleChains*(p: SetPool): int =
  if p == nil: return 0
  withLock p.lock: result = p.idle.len

proc leasedChains*(p: SetPool): int =
  if p == nil: return 0
  withLock p.lock: result = p.leasedNow

when shmGSetSupported and defined(shmGSetScheduleHooks):
  proc forceIdleGenerationsForTest*(p: SetPool; g: uint64): int {.discardable.} =
    ## TEST-ONLY seam, compile-time gated exactly like the transport's
    ## `forceGenerationForTest`: drive every IDLE chain's generation counter, so
    ## the `rsGenerationExhausted` ⇒ RETIRE policy is reachable in a test rather
    ## than after 4.29e9 real recycles. Returns how many chains were touched.
    if p == nil or not p.ownsThisProcess(): return 0
    withLock p.lock:
      for pc in p.idle.mitems:
        pc.host.forceGenerationForTest(g)
        inc result

proc close*(p: SetPool): int {.discardable.} =
  ## Retire every idle chain and unlink its files. Returns the number of leases
  ## still OUTSTANDING, and that number is the caller's whole signal:
  ##
  ## - **0** — every chain came back, every file is gone, the pool left nothing
  ##   on disk.
  ## - **> 0** — that many leases were never released, and *their shard files
  ##   are still on disk after this call*. `close` deliberately does not unlink
  ##   them: from the pool's side a lease an action is still writing to and a
  ##   lease that was dropped and will never come back are the same state, and
  ##   unlinking the live one is exactly the "reap a live segment" fault this
  ##   library's owner-pid rule exists to prevent. A caller that sees a nonzero
  ##   result has leases to account for; the files are swept by
  ##   `destroySetPool`, which is where the host declares the pool dead.
  ## - **-1** — called from a process that did not create this pool. Nothing was
  ##   touched. (`close` REPORTS the refusal; `acquire` reports it as
  ##   `prForeignProcess` on the lease; `destroySetPool` reports it by leaving
  ##   `p` non-nil; `release` can only drop it silently, having no channel to
  ##   report on — see `release`.)
  ##
  ## A closed pool stays safely CALLABLE: `acquire` returns `prClosed` and
  ## `release` still retires the chain handed back.
  if p == nil: return 0
  if not p.ownsThisProcess(): return -1
  withLock p.lock:
    p.closed = true
    while p.idle.len > 0:
      var pc = move(p.idle[^1])
      p.idle.setLen(p.idle.len - 1)
      p.retireLocked(pc, rrPoolClosed)
    result = p.leasedNow

proc destroySetPool*(p: var SetPool) =
  ## `close` the pool and release the shared object itself. Separate from
  ## `close` because `close` must leave a closed pool safely CALLABLE — an
  ## `acquire` racing a shutdown has to get `prClosed`, not a use-after-free —
  ## so freeing is an explicit, later step the host takes when it knows no
  ## thread will touch the pool again. Safe to call on `nil`; leaves `p` nil.
  ##
  ## OWNER-ONLY, like `acquire` / `release` / `close`, and the guard is the
  ## FIRST thing this proc does — before `close`, before the sweep, before the
  ## lock. It has to be: the sweep below `unlink`s shard files, and this is the
  ## only entry point that unlinks UNCONDITIONALLY, so an unguarded
  ## `destroySetPool` in a fork child deletes a chain the PARENT is mid-action
  ## on. That is strictly worse than the fault the ownership section exists to
  ## prevent. A child's stray `markConsumerGone` at least leaves the parent's
  ## producers fast-failing VISIBLY with `emConsumerGone`; an unlinked anchor
  ## leaves them unable to `attachProducer` at all — the action is unmonitored
  ## and nothing says so.
  ##
  ## A FOREIGN PROCESS MAY NOT EVEN FREE ITS OWN COW COPY, and that was decided
  ## rather than inherited. `allocShared` memory is process-local (the shared
  ## heap is shared between THREADS, not processes), so a fork child freeing the
  ## struct harms no other process — but it buys nothing and costs three things:
  ##
  ## 1. `deinitLock` is `pthread_mutex_destroy`, which is undefined on a LOCKED
  ##    mutex. A `fork()` from a multi-threaded host — the shape this pool is
  ##    built for — copies the mutex in whatever state it was in, so the child's
  ##    copy may well be locked by a thread that does not exist in the child.
  ## 2. Setting `p = nil` DOWNGRADES the child's later diagnostics: `acquire` on
  ##    a nil pool answers `prClosed`, which is a lie — the pool is not closed,
  ##    this process is not its owner — where `prForeignProcess` names the real
  ##    reason. Refusing keeps the one refusal that names the reason available.
  ## 3. There is nothing to reclaim. A fork child's two honest fates are `_exit`
  ##    and `exec`, and both drop the whole address space anyway.
  ##
  ## So: nothing happens and `p` STAYS NON-NIL. Unlike `release`, that is not
  ## silent — `p != nil` after the call is the refusal, and it is the fourth of
  ## the four distinct refusal channels tabulated in this module's header.
  ##
  ## FINAL SWEEP. `close` refuses to unlink while a lease is outstanding — it
  ## cannot tell a lease that was dropped from one an action is still writing
  ## to. `destroySetPool` is the point where the host declares that no thread
  ## will ever touch this pool again, so a chain the pool created and never got
  ## back is abandoned BY DEFINITION here, and leaving its files on disk is the
  ## 61 GiB failure in miniature (the reaper collects only when the owner pid is
  ## dead, and the owner is this process). Hence `created` is swept
  ## unconditionally, after `close` has already retired everything idle.
  ##
  ## What this sweep CANNOT do, stated so it is not discovered later: the pool
  ## holds no handle to an outstanding chain (`acquire` moved the `SetHost` into
  ## the lease), so it can unlink the names but cannot `markConsumerGone` on it.
  ## A producer still attached to a dropped lease's chain therefore keeps a
  ## valid mapping — POSIX inode refcounting — and can still insert, and a shard
  ## it links after the unlink is a new file the sweep has already passed. That
  ## is the price of a dropped lease, and the answer to it is `release`, not a
  ## bigger sweep.
  ##
  ## The GC'd fields are then ASSIGNED AWAY rather than truncated. `setLen(0)`
  ## destroys the elements but KEEPS the seq's payload buffer, which the
  ## `deallocShared` below would then orphan — 136 bytes "definitely lost" under
  ## `valgrind --leak-check=full`, since the raw allocation carries no
  ## destructor to run `=destroy` on the fields. Assigning an empty seq frees the
  ## payload. `just test-valgrind` gates exactly this, and
  ## `destroySetPool_frees_the_pools_own_buffers` gates it from inside the suite.
  ## 136 bytes is the PER-POOL figure; the valgrind gate's probe drives TWO pool
  ## lifecycles, so reverting this measures `272 bytes in 2 blocks` /
  ## `ERROR SUMMARY: 2 errors from 2 contexts`, one loss record per pool.
  if p == nil: return
  if not p.ownsThisProcess(): return   # a fork child: touch NOTHING, and leave
                                       # `p` non-nil so the caller can tell
  discard p.close()
  withLock p.lock:
    for c in p.created: unlinkChain(c)
    p.created = @[]
  p.dir = ""
  p.appId = ""
  p.idle = @[]
  p.created = @[]
  deinitLock(p.lock)
  deallocShared(p)
  p = nil
