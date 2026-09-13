## Common producer/consumer interface (design spec §5) — SET implementation.
##
## Asserts the transport-agnostic surface: the host lifecycle (create → path0 →
## snapshot/merge → detach), the producer `emit` status mapping
## ({inserted|exists|consumerGone|oversize|saturated|unavailable}), that the hot
## path is serialization-free (opaque byte blobs), and that a multi-process
## fork/probe-storm through `emit` yields the exact union (LF-1). Every check
## asserts.

import std/[os, sets, strutils, unittest]
import shm_gset/transport
import ./xproc

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
