## Common producer/consumer interface (io-mon-Lossless-Event-Capture §5).
##
## A transport-AGNOSTIC surface both lossless shared-memory models sit behind, so
## the transport is a swappable config/compile choice and never a rewrite. This
## file provides the **SET** implementation (Candidate C, the M1 winner); a ring
## implementation exposes the same shape from `nim-shm-queue`.
##
## The interface owns the *lifecycle* so a well-formed parent cannot end up with a
## producer and no consumer (closing the LF-2 gap where a hand-rolled host forgets
## to register the consumer):
##
##   host:  startHost(dir, runId)  ->  path0  ->  {snapshot/items, growthFailures}
##          ->  finish()   (mark-gone + detach)
##   prod:  attachProducer(path0)  ->  emit(blob)*  ->  detach()
##
## Serialization-free hot path: `emit` takes an opaque `openArray[byte]` and
## copies it straight into the intern arena — no codec, no heap allocation. The
## element key/value codec is io-mon's Layer 2/3, above this surface.

import ../shm_gset
export shm_gset.ShmGSet   # transports may hand back the raw view when useful

type
  EmitStatus* = enum
    ## The producer-side outcome, unified across transports (§5). The SET never
    ## returns a "spilled to file" outcome — it grows instead (LF-5).
    emInserted     ## a NEW element was published into the set
    emExists       ## the element was already present (idempotent no-op)
    emConsumerGone ## the host/consumer marked itself gone (LF-4 fast-fail)
    emOversize     ## element exceeds the producer's hard cap ⇒ `mcIncomplete`
    emSaturated    ## growth itself failed (OOM): SIGNALLED, never a silent drop
    emUnavailable  ## not attached (LF-2 fail-fast / portable no-op arm)

  SetProducer* = object
    ## Producer-side handle over an attached shard chain.
    s: ShmGSet
    maxElementBytes: int   ## 0 == unlimited; the SET's growth absorbs oversize
                           ## (LF-5), so a nonzero cap is only for a transport
                           ## that genuinely cannot frame an element.

  SetHost* = object
    ## Consumer/host-side lifecycle owner (create → path0 → snapshot → detach).
    s: ShmGSet

# --- producer side ----------------------------------------------------------

proc attachProducer*(path0: string; maxElementBytes = 0): SetProducer =
  ## Attach a producer to a host-created chain via shard0's well-known path
  ## (`REPRO_MONITOR_DEP_SHM`). `maxElementBytes = 0` means unlimited (the SET
  ## grows to fit any element); a nonzero cap makes `emit` report `emOversize`
  ## for elements it must refuse — the `mcIncomplete` path.
  result.maxElementBytes = maxElementBytes
  result.s = attachSet(path0)

proc available*(p: SetProducer): bool = p.s.available

proc emit*(p: var SetProducer; blob: openArray[byte]): EmitStatus =
  ## Idempotent, non-blocking, serialization-free insert. Maps the SET's insert
  ## outcome onto the transport-agnostic `EmitStatus`. A re-observed element is a
  ## single CAS that finds it present (`emExists`), so backpressure never arises.
  if not p.s.available: return emUnavailable
  if p.maxElementBytes > 0 and blob.len > p.maxElementBytes:
    return emOversize
  if not p.s.consumerAlive:
    return emConsumerGone
  case p.s.insert(blob)
  of isInserted: emInserted
  of isExists: emExists
  of isSaturated: emSaturated
  of isUnavailable: emUnavailable

proc detach*(p: var SetProducer) = p.s.detach()

# --- consumer / host side ---------------------------------------------------

proc startHost*(dir, runId: string; appId = "io-mon"; shard0Cap = 1024;
    shard0ArenaCap = 256 * 1024): SetHost =
  ## Create shard0 (the well-known anchor) and register this process as the live
  ## consumer. Hand `path0` to producers via `REPRO_MONITOR_DEP_SHM`. `appId`
  ## scopes the cross-restart reaper so one app never reaps another's segments
  ## (defaults to `"io-mon"`; a different consumer, e.g. reprobuild/codetracer,
  ## passes its own tag).
  result.s = createSet(dir, appId, runId, shard0Cap = shard0Cap,
    shard0ArenaCap = shard0ArenaCap)

proc available*(h: SetHost): bool = h.s.available
proc path0*(h: SetHost): string = h.s.path0

iterator items*(h: var SetHost): seq[byte] =
  ## Single-threaded merged distinct set (the depfile source of truth, §4.3.3).
  for e in h.s.items: yield e

proc snapshot*(h: var SetHost): seq[seq[byte]] = h.s.snapshot()
proc growthFailures*(h: var SetHost): uint64 = h.s.growthFailures()
proc shardCount*(h: var SetHost): int = h.s.shardCount()
proc claimedSlots*(h: var SetHost): uint64 = h.s.claimedSlots()

proc finish*(h: var SetHost) =
  ## End the host lifecycle: announce the consumer is gone (so any late producer
  ## `emit` fast-fails with `emConsumerGone`), then unmap.
  h.s.markConsumerGone()
  h.s.detach()
