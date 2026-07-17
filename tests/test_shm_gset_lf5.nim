## LF-5 (oversize is not loss) for the SET (design spec §4.4a, LF-5).
##
## Two asserting proofs:
##   1. An element LARGER than a shard's arena is captured by GROWTH — the set
##      grows a bigger shard and the element is present in `snapshot`, never
##      dropped.
##   2. A genuinely impossible allocation surfaces as SIGNALLED saturation
##      (`growthFailures` > 0 and `insert` == `isSaturated`), never a silent drop.
##      We force it deterministically by pre-creating the next shard's final path
##      as a DIRECTORY, so the atomic `link()` publish can never succeed — the
##      real "the OS refused to create the shard file" case.

import std/[os, posix, sets, strutils, unittest]
import shm_gset

var tmpCtr = 0
proc freshDir(tag: string): string =
  inc tmpCtr
  result = getTempDir() / ("shmgset-lf5-" & tag & "-" & $getpid() & "-" & $tmpCtr)
  removeDir(result); createDir(result)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc strOf(b: seq[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len: result[i] = char(b[i])

proc shardPathOf(path0: string; k: int): string =
  ## path0 is `<basePrefix>.shard0`; sibling shard k shares the base prefix.
  doAssert path0.endsWith(".shard0")
  path0[0 ..< path0.len - ".shard0".len] & ".shard" & $k

suite "LF-5 (oversize is not loss)":
  test "an element bigger than the shard arena is captured by growth":
    let dir = freshDir("grow")
    defer: removeDir(dir)
    # Tiny arena so the big element cannot fit in shard0 and MUST force a grow.
    const arenaCap = 2048
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 64, shard0ArenaCap = arenaCap)
    check s.available

    # An element several times the arena capacity: growth (arena *= GrowthFactor
    # per shard) must eventually make a shard whose arena holds it.
    var big = newSeq[byte](arenaCap * 3 + 137)
    for i in 0 ..< big.len: big[i] = byte((i * 31 + 7) and 0xff)
    check s.insert(big) in {isInserted, isExists}
    check s.shardCount() > 1                    # it actually grew
    check s.growthFailures() == 0               # growth SUCCEEDED — no drop

    # The oversize element is present AND byte-for-byte intact (no torn store).
    check s.contains(big)
    var found = false
    for e in s.items:
      if e.len == big.len:
        check e == big
        found = true
    check found

    # A few normal elements alongside it still union cleanly.
    check s.insert(bytesOf("small-a")) in {isInserted, isExists}
    check s.insert(bytesOf("small-b")) in {isInserted, isExists}
    var got = initHashSet[string]()
    for e in s.items:
      if e.len < 64: got.incl strOf(e)
    check "small-a" in got and "small-b" in got
    s.detach()

  test "a genuinely impossible allocation SIGNALS saturation, never silent drop":
    let dir = freshDir("sat")
    defer: removeDir(dir)
    # Small geometry so growth is attempted quickly.
    var s = createSet(dir, "io-mon", "edge", shard0Cap = 32, shard0ArenaCap = 1024)
    check s.available
    let path0 = s.path0

    # Make the shard-append physically impossible: occupy shard1's FINAL path with
    # a directory, so the atomic link() publish can never succeed. This is a real
    # "the OS refused to create the shard file" failure, not a fake.
    createDir(shardPathOf(path0, 1))

    # Insert distinct elements until shard0 is exhausted and growth is forced.
    # Every distinct element must be either accepted (still in shard0) or
    # SIGNALLED as saturated — never silently swallowed.
    var sawSaturated = false
    var accepted = initHashSet[string]()
    for i in 0 ..< 400:
      let e = "dep-" & $i
      case s.insert(bytesOf(e))
      of isInserted, isExists: accepted.incl e
      of isSaturated: sawSaturated = true
      of isUnavailable: check false             # never on a live set

    check sawSaturated                          # saturation WAS signalled
    check s.growthFailures() > 0                # SIGNALLED counter is nonzero
    # Growth never produced a real shard file (the link publish always failed);
    # the failure is loud, not a leaked/half-shard.
    check (not fileExists(shardPathOf(path0, 1)))

    # Every element the set ACCEPTED is actually present (no lost accepted elem):
    # the failure is confined to the signalled-saturation elements.
    for e in accepted:
      check s.contains(bytesOf(e))
    s.detach()
