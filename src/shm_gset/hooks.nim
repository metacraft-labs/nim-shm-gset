## Deterministic schedule-hook seams for `nim-shm-gset` (design spec §4.5(c)).
##
## Every concurrency-sensitive site in the set (slot-claim CAS, arena-offset
## publish, shard-link publish, chain-count bump) calls `scheduleHook(point)`.
## In a normal build the hook is a **compile-time no-op** (the call folds away),
## so it costs nothing on the hot path. Under `-d:shmGSetScheduleHooks` a test can
## install a callback that yields / sleeps / coordinates at a chosen point to
## drive a specific interleaving deterministically — this is the scaffolding M2's
## adversarial-interleaving regression tests build on, landed here so the
## verification harness is not a retrofit (M1 exit criteria).
##
## The hook is a plain thread-local proc pointer, so it works for the in-process
## thread harness (TSAN / deterministic scheduling). It deliberately does NOT
## reach across a process boundary — cross-process interleaving is driven by the
## kill-injection / delay-injection harness, not by this callback.

type
  SchedulePoint* = enum
    ## The publishing / CAS sites a test may intercept. Kept stable so a test
    ## refers to a point by name, not by ordinal.
    spBeforeSlotCas       ## about to CAS an empty slot 0 -> element-offset
    spAfterSlotCas        ## just after the slot-claim CAS (won or lost)
    spBeforeArenaPublish  ## element bytes written; about to make the arena
                          ## record reachable via the slot
    spBeforeShardLink     ## new shard file initialised; about to link it into
                          ## the run directory under its final name
    spAfterShardLink      ## shard file linked; about to bump the chain count
    spBeforeChainBump     ## about to CAS shard0.chainCount n -> n+1
    spBeforeArenaReserve  ## about to CAS the generation-stamped arena bump
                          ## pointer (reserve or rebase)
    # --- reset / recycling publish points (HM-2) ---
    # These four bracket the ONLY writes `reset` performs, in the order it
    # performs them, so a kill-injection harness can crash a host at each and
    # assert the chain reads as fully-old or fully-new — never half-reset.
    spBeforeRunIdStamp    ## about to stamp the NEXT generation's runId slot
    spBeforeLivenessRearm ## runId stamped; about to re-arm the consumer token
    spBeforeGenerationPublish ## everything staged; about to release-store the
                          ## new generation — the atomic commit point
    spAfterGenerationPublish  ## committed; about to drop the reset seal

  ScheduleHook* = proc (point: SchedulePoint) {.gcsafe, raises: [].}

when defined(shmGSetScheduleHooks):
  var activeHook {.threadvar.}: ScheduleHook

  proc setScheduleHook*(h: ScheduleHook) =
    ## Install (or clear, with `nil`) the current thread's schedule hook. Only
    ## available under `-d:shmGSetScheduleHooks`.
    activeHook = h

  proc scheduleHook*(point: SchedulePoint) {.inline.} =
    let h = activeHook
    if h != nil:
      h(point)

  const scheduleHooksEnabled* = true
else:
  proc scheduleHook*(point: SchedulePoint) {.inline.} = discard
    ## Compile-time no-op: the call is erased in a normal build.

  const scheduleHooksEnabled* = false
