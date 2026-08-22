## NEGATIVE-COMPILATION fixture for `pool_never_hands_out_an_unreset_chain`.
##
## A `SetLease` is exclusive: `pool.nim` disables `=copy` for it, because a
## copied lease released twice would put ONE chain into the idle list twice and
## the next two acquires would hand the same shards to two concurrent actions.
## That is a compile error, and it must be asserted as one.
##
## It cannot be asserted with `compiles()`: the `=copy` hook is injected in the
## `injectdestructors` pass, AFTER the sem phase `compiles()` reports on, so
## `compiles(var dup: SetLease = a)` answers TRUE while `nim c` on the same code
## fails. So the property is checked by compiling this file for real, both ways:
##
##   nim c ...                        lease_copy_probe.nim   -> MUST FAIL with
##                                    "'=copy' is not available for type <SetLease>"
##   nim c ... -d:leaseProbeMove      lease_copy_probe.nim   -> MUST SUCCEED
##
## The `-d:leaseProbeMove` arm is the positive control: without it, a fixture
## that failed to compile for some unrelated reason (a typo, a missing import)
## would look exactly like a passing test.

import std/[os]
import shm_gset/pool

let dir = getTempDir() / "shmgset-lease-copy-probe"
removeDir(dir)
createDir(dir)
var p = newSetPool(dir, "io-mon", shard0Cap = 64, shard0ArenaCap = 2048)
var a = p.acquire("probe")
doAssert a.available

when defined(leaseProbeMove):
  var dup: SetLease = move(a)          # explicit move: legal
  doAssert dup.available
  dup.release()
else:
  var dup: SetLease = a                # a COPY: must not compile
  doAssert dup.available
  dup.release()
  a.release()

discard p.close()
removeDir(dir)
