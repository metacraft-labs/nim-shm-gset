## Common producer/consumer interface (design spec §5) — SET implementation.
##
## Asserts the transport-agnostic surface: the host lifecycle (create → path0 →
## snapshot/merge → detach), the producer `emit` status mapping
## ({inserted|exists|consumerGone|oversize|saturated|unavailable}), that the hot
## path is serialization-free (opaque byte blobs), and that a multi-process
## fork/probe-storm through `emit` yields the exact union (LF-1). The
## async-signal-safe `emitNoGrow` is graded too: it publishes into shard0, never
## grows the chain, bumps the growth-failure counter when shard0 cannot take
## the element, and works from inside a real signal handler. Every check
## asserts.

import std/[os, sets, strutils, unittest]
import shm_gset/transport
import ./xproc
when defined(posix):
  import std/posix

var tmpCtr = 0
proc freshDir(tag: string): string = freshTestDir("shmgset-xport", tag, tmpCtr)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

# --- child roles (see tests/xproc.nim) --------------------------------------

proc stormProducer(args: seq[string]) =
  ## One producer of the LF-1 probe storm: attach to `path0`, emit `perProc`
  ## distinct elements `dupFactor` times each, detach. Everything it needs is in
  ## `args`, so the same body is a forked child on POSIX and a spawned one on
  ## Windows.
  let
    path0 = args[0]
    c = parseInt(args[1])
    perProc = parseInt(args[2])
    dupFactor = parseInt(args[3])
  var pr = attachProducer(path0)
  if not pr.available: exitChild(2)
  for j in 0 ..< perProc:
    let e = bytesOf("c" & $c & "/dep-" & $j)
    for _ in 0 ..< dupFactor:
      case pr.emit(e)
      of emInserted, emExists: discard
      else: (pr.detach(); exitChild(3))
  pr.detach()
  exitChild(0)

registerChildRole("stormProducer", stormProducer)
xprocChildEntry()

suite "transport interface (design spec §5)":
  test "host lifecycle + producer emit status mapping":
    let dir = freshDir("emit")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check host.available
    check host.path0.endsWith(".shard0")

    var prod = attachProducer(host.path0)
    check prod.available
    check prod.emit(bytesOf("alpha")) == emInserted
    check prod.emit(bytesOf("beta")) == emInserted
    check prod.emit(bytesOf("alpha")) == emExists      # idempotent
    check prod.emit(bytesOf("alpha")) == emExists
    check prod.emit(newSeq[byte](0)) == emInserted     # empty element allowed

    # Host reads the merged distinct set (source of truth).
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got.len == 3
    check "alpha" in got and "beta" in got and "" in got
    check host.growthFailures() == 0

    # Once the host finishes (marks consumer gone), a late producer emit
    # fast-fails with emConsumerGone (LF-4) instead of writing to an orphan.
    prod.detach()
    var late = attachProducer(host.path0)
    check late.available
    host.finish()
    check late.emit(bytesOf("gamma")) == emConsumerGone
    late.detach()

  test "unavailable producer (LF-2 fail-fast) reports emUnavailable":
    let dir = freshDir("unavail")
    defer: removeDir(dir)
    var prod = attachProducer(dir / "does-not-exist.shard0")
    check (not prod.available)
    check prod.emit(bytesOf("x")) == emUnavailable

  test "oversize cap ⇒ emOversize (mcIncomplete path)":
    let dir = freshDir("oversize")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check host.available
    # A producer with a hard 8-byte frame cap refuses larger elements rather than
    # dropping them silently; io-mon turns emOversize into an mcIncomplete marker.
    var prod = attachProducer(host.path0, maxElementBytes = 8)
    check prod.available
    check prod.emit(bytesOf("tiny")) == emInserted        # 4 bytes: fits
    check prod.emit(bytesOf("this-is-way-too-long")) == emOversize
    # The oversize element is NOT in the set (refused, not torn/half-written).
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == toHashSet(@["tiny"])
    check host.growthFailures() == 0
    host.finish()

  test "multi-process probe storm through emit == exact union (LF-1)":
    let dir = freshDir("storm")
    defer: removeDir(dir)
    const
      nProc = 4
      perProc = 700
      dupFactor = 6
    var host = startHost(dir, "edge", shard0Cap = 128, shard0ArenaCap = 4096)
    check host.available
    let path0 = host.path0

    var kids: seq[Child]
    for c in 0 ..< nProc:
      kids.add startChild("stormProducer", path0, c, perProc, dupFactor)
    for k in kids.mitems:
      check waitChild(k) == 0

    var expected = initHashSet[string]()
    for c in 0 ..< nProc:
      for j in 0 ..< perProc:
        expected.incl("c" & $c & "/dep-" & $j)
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got.len == nProc * perProc          # zero loss
    check got == expected                      # zero phantom
    check host.growthFailures() == 0
    host.finish()

# The producer the signal-handler case publishes through. A global, because a
# signal handler takes no argument; it is attached before the handler is
# installed and detached after the signal has been handled.
var signalProducer: SetProducer
var signalEmitStatus: EmitStatus

when defined(posix):
  proc c_raise(signum: cint): cint {.importc: "raise", header: "<signal.h>".}
    ## raise(3): the signal is handled before it returns (POSIX).

  proc emitFromSignalHandler(signum: cint) {.noconv.} =
    signalEmitStatus = signalProducer.emitNoGrow(
      [byte('s'), byte('i'), byte('g')])

suite "emitNoGrow: the async-signal-safe, never-growing emit":
  test "publishes into shard0 and never grows the chain":
    let dir = freshDir("nogrow")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check host.available
    var prod = attachProducer(host.path0)
    check prod.available
    check prod.emitNoGrow(bytesOf("loss")) == emInserted
    check prod.emitNoGrow(bytesOf("loss")) == emExists     # idempotent
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == toHashSet(@["loss"])
    check host.shardCount() == 1
    check host.growthFailures() == 0
    prod.detach()
    host.finish()

  test "after the chain grew, a no-grow element lands in shard0 and is read":
    let dir = freshDir("nogrow-grown")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 8, shard0ArenaCap = 1024)
    check host.available
    var prod = attachProducer(host.path0)
    check prod.available
    for j in 0 ..< 200:
      check prod.emit(bytesOf("dep-" & $j)) == emInserted
    let grown = host.shardCount()
    check grown > 1
    # shard0 is full by now, so a fresh element may not fit; either outcome is
    # a sound one, and neither grows the chain.
    let st = prod.emitNoGrow(bytesOf("late"))
    check st in {emInserted, emSaturated}
    check host.shardCount() == grown
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got.len == 200 + (if st == emInserted: 1 else: 0)
    if st == emInserted:
      check "late" in got
      check host.growthFailures() == 0
    else:
      check host.growthFailures() == 1
    prod.detach()
    host.finish()

  test "a full shard0 bumps the growth-failure counter instead of growing":
    let dir = freshDir("nogrow-full")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 8, shard0ArenaCap = 4096)
    check host.available
    var prod = attachProducer(host.path0)
    check prod.available
    var inserted = 0
    var saturated = false
    for j in 0 ..< 64:
      case prod.emitNoGrow(bytesOf("e-" & $j))
      of emInserted: inc inserted
      of emSaturated:
        saturated = true
        break
      else:
        check false
    check saturated
    check inserted > 0
    check host.shardCount() == 1               # never grew
    check host.growthFailures() == 1           # signalled, never silent
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got.len == inserted                  # nothing torn or half-written
    prod.detach()
    host.finish()

  test "an element over the producer's cap is refused, not published":
    let dir = freshDir("nogrow-oversize")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check host.available
    var prod = attachProducer(host.path0, maxElementBytes = 8)
    check prod.available
    check prod.emitNoGrow(bytesOf("tiny")) == emInserted
    check prod.emitNoGrow(bytesOf("this-is-way-too-long")) == emOversize
    var got = initHashSet[string]()
    for e in host.items: got.incl strOf(e)
    check got == toHashSet(@["tiny"])
    check host.growthFailures() == 0          # refused, not a growth failure
    prod.detach()
    host.finish()

  test "a detached or never-attached producer is unavailable":
    let dir = freshDir("nogrow-detached")
    defer: removeDir(dir)
    var host = startHost(dir, "edge", shard0Cap = 64, shard0ArenaCap = 8192)
    check host.available
    var prod = attachProducer(host.path0)
    check prod.available
    prod.detach()
    check prod.emitNoGrow(bytesOf("x")) == emUnavailable
    var missing = attachProducer(dir / "does-not-exist.shard0")
    check missing.emitNoGrow(bytesOf("x")) == emUnavailable
    check host.growthFailures() == 0
    host.finish()

  when not defined(posix):
    notApplicableHere("publishes from inside a real signal handler",
      "the case delivers a POSIX signal to the test process and publishes " &
      "from its handler. Windows has no POSIX signals; the call itself is " &
      "covered there by the other no-grow cases, which make the same insert " &
      "outside a handler.")
  else:
    test "publishes from inside a real signal handler":
      let dir = freshDir("nogrow-signal")
      defer: removeDir(dir)
      var host = startHost(dir, "edge", shard0Cap = 64, shard0ArenaCap = 8192)
      check host.available
      signalProducer = attachProducer(host.path0)
      check signalProducer.available
      signalEmitStatus = emUnavailable
      var sa, old: Sigaction
      sa.sa_handler = emitFromSignalHandler
      check sigemptyset(sa.sa_mask) == 0
      sa.sa_flags = 0
      check sigaction(SIGUSR1, sa, old) == 0
      check c_raise(SIGUSR1) == 0
      check sigaction(SIGUSR1, old, nil) == 0
      check signalEmitStatus == emInserted
      var got = initHashSet[string]()
      for e in host.items: got.incl strOf(e)
      check got == toHashSet(@["sig"])
      signalProducer.detach()
      host.finish()
