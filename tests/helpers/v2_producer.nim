## A STANDALONE nim-shm-gset producer/writer speaking the **rev-2** (HM-1)
## on-disk header layout — the layout this library used before slots became
## generation-stamped.
##
## WHY IT EXISTS, and why it is not a mock. The version-skew diagnostic has to be
## tested against a genuinely version-skewed peer, and a peer is by definition a
## SEPARATE BUILD: one that validates a different magic, computes a different
## header size and writes un-stamped slot entries. This file is exactly that — an
## independent, self-contained implementation of the previous on-disk contract,
## importing nothing from `../../src`. It stands in for nothing: it IS the other
## side of the skew, in a real process, over real `mmap`ed shared memory.
##
## It is deliberately usable in BOTH directions, because a "producer" that always
## failed would prove nothing:
##
##   v2_producer write   <path0>          — write a genuine rev-2 chain
##   v2_producer produce <path0> <elem>   — attach as a rev-2 producer and insert
##
## `produce` exits:
##   0  — attached and inserted (or found present). The rev-2 protocol WORKS.
##   10 — refused: the magic's layout-revision byte is not 2. THE SKEW.
##   11 — refused for any other reason (missing file, wrong boot, table full).
##
## Running `produce` successfully against a chain this same program `write`s is
## what proves that its refusal against a rev-3 chain is about the SKEW and not
## about the program being broken.
##
## The offsets and constants below are spelled out as literals rather than taken
## from `shm_gset`'s `ShOff*` — precisely because those have moved and will move
## again. This file must keep describing rev 2 however the current layout evolves.

import std/[os, posix, strutils]

const
  V2Magic = 0x5347_4D48_53_00_02'u64   # "SHM SG", layout revision 2
  V2FormatVersion = 1'u32              # the IdentityKey discipline
  V2HeaderSize = 256
  OffMagic = 0
  OffFormatVersion = 8
  OffFlags = 12
  OffCreatorBootId = 16
  OffShardId = 24
  OffCapacity = 32
  OffSlotsOff = 40
  OffArenaOff = 48
  OffArenaCap = 56
  OffArenaUsed = 64
  OffOccupied = 72
  OffChainCount = 80
  OffGrowthFailed = 88
  OffConsumerPid = 96
  OffConsumerBoot = 104
  OffConsumerAlive = 112
  OffRunIdLen = 120
  OffRunId = 128
  RunIdMax = 120
  ArenaRecFp = 0
  ArenaRecLen = 8
  ArenaRecBytes = 16
  ArenaRecHdr = 16

func alignUp(n, a: int): int = (n + a - 1) and not (a - 1)

func fnv(blob: openArray[byte]): uint64 =
  result = 1469598103934665603'u64
  for b in blob:
    result = (result xor uint64(b)) * 1099511628211'u64

proc bootId(): uint64 =
  ## Byte-for-byte the same derivation rev 2 used, so the boot guard passes for
  ## a chain written by either side.
  try:
    let raw = readFile("/proc/sys/kernel/random/boot_id")
    var h: uint64 = 1469598103934665603'u64
    for ch in raw:
      if ch != '-' and ch != '\n':
        h = (h xor uint64(ord(ch))) * 1099511628211'u64
    return (h or 1'u64)
  except CatchableError: discard
  1'u64

type Base = ptr UncheckedArray[byte]

proc getU64(b: Base; off: int): uint64 =
  copyMem(addr result, addr b[off], 8)
proc putU64(b: Base; off: int; v: uint64) =
  var x = v
  copyMem(addr b[off], addr x, 8)
proc getU32(b: Base; off: int): uint32 =
  copyMem(addr result, addr b[off], 4)
proc putU32(b: Base; off: int; v: uint32) =
  var x = v
  copyMem(addr b[off], addr x, 4)

proc mapFile(path: string; size: var int): Base =
  let fd = open(path.cstring, O_RDWR)
  if fd < 0: return nil
  try: size = int(getFileSize(path))
  except CatchableError:
    discard close(fd); return nil
  if size <= V2HeaderSize:
    discard close(fd); return nil
  let p = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  discard close(fd)
  if p == MAP_FAILED: return nil
  cast[Base](p)

proc writeChain(path0, runId: string; cap, arenaCap: int) =
  let slotsOff = V2HeaderSize
  let arenaOff = alignUp(slotsOff + cap * 8, 64)
  let size = alignUp(arenaOff + arenaCap, 4096)
  var buf = newSeq[byte](size)
  writeFile(path0, buf)
  var sz = 0
  let b = mapFile(path0, sz)
  doAssert b != nil
  let boot = bootId()
  putU32(b, OffFormatVersion, V2FormatVersion)
  putU32(b, OffFlags, 0)
  putU64(b, OffCreatorBootId, boot)
  putU64(b, OffShardId, 0)
  putU64(b, OffCapacity, uint64(cap))
  putU64(b, OffSlotsOff, uint64(slotsOff))
  putU64(b, OffArenaOff, uint64(arenaOff))
  putU64(b, OffArenaCap, uint64(arenaCap))
  putU64(b, OffArenaUsed, 8)             # rev 2's guard word
  putU64(b, OffOccupied, 0)
  putU64(b, OffChainCount, 1)
  putU64(b, OffGrowthFailed, 0)
  putU64(b, OffConsumerPid, uint64(getpid()))
  putU64(b, OffConsumerBoot, boot)
  putU64(b, OffConsumerAlive, 1)
  let rn = min(runId.len, RunIdMax)
  if rn > 0: copyMem(addr b[OffRunId], unsafeAddr runId[0], rn)
  putU32(b, OffRunIdLen, uint32(rn))
  putU64(b, OffMagic, V2Magic)           # magic LAST, as rev 2 did
  discard munmap(cast[pointer](b), sz)

proc produce(path0, elem: string): int =
  var size = 0
  let b = mapFile(path0, size)
  if b == nil: return 11
  defer: discard munmap(cast[pointer](b), size)
  let magic = getU64(b, OffMagic)
  if magic != V2Magic:
    # THE SKEW: a genuine layout disagreement. rev 2 had no way to say so —
    # it simply reported "unavailable" and the dependency set came back empty.
    stderr.writeLine "v2_producer: layout skew — file magic 0x" &
      toHex(magic, 16) & ", this build speaks rev 2"
    return 10
  if getU32(b, OffFormatVersion) != V2FormatVersion: return 11
  if getU64(b, OffCreatorBootId) != bootId(): return 11
  if getU64(b, OffConsumerAlive) == 0: return 11
  let cap = int(getU64(b, OffCapacity))
  let slotsOff = int(getU64(b, OffSlotsOff))
  let arenaOff = int(getU64(b, OffArenaOff))
  let arenaCap = int(getU64(b, OffArenaCap))
  var blob = newSeq[byte](elem.len)
  for i, c in elem: blob[i] = byte(c)
  let fp = fnv(blob) or 1'u64
  let mask = uint64(cap - 1)
  var idx = int(fp and mask)
  var probes = 0
  while probes < cap:
    let slot = slotsOff + idx * 8
    let entry = getU64(b, slot)
    if entry == 0'u64:                   # rev 2: a bare offset, 0 == empty
      let recSize = alignUp(ArenaRecHdr + blob.len, 8)
      let used = int(getU64(b, OffArenaUsed))
      if used + recSize > arenaCap: return 11
      putU64(b, OffArenaUsed, uint64(used + recSize))
      let absOff = arenaOff + used
      putU64(b, absOff + ArenaRecFp, fp)
      putU32(b, absOff + ArenaRecLen, uint32(blob.len))
      if blob.len > 0:
        copyMem(addr b[absOff + ArenaRecBytes], addr blob[0], blob.len)
      putU64(b, slot, uint64(absOff))    # rev 2: publish the bare offset
      putU64(b, OffOccupied, getU64(b, OffOccupied) + 1)
      return 0
    if getU64(b, int(entry) + ArenaRecFp) == fp: return 0   # already present
    idx = (idx + 1) and int(mask); inc probes
  11

when isMainModule:
  if paramCount() < 2:
    stderr.writeLine "usage: v2_producer write|produce <path0> [elem]"
    quit 2
  case paramStr(1)
  of "write":
    writeChain(paramStr(2), (if paramCount() >= 3: paramStr(3) else: "v2-run"),
      64, 4096)
    quit 0
  of "produce":
    quit produce(paramStr(2), (if paramCount() >= 4: paramStr(4) else: "v2-elem"))
  else:
    stderr.writeLine "unknown mode " & paramStr(1)
    quit 2
