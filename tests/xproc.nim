## Portable multi-process test harness.
##
## Most of this suite's strongest properties are about a REAL PROCESS BOUNDARY —
## a separate address space mapping the same shard files, so any absolute pointer
## that leaked into shared memory faults, and any lost update is a genuine
## cross-process race rather than a thread-scheduling artifact. Those tests were
## written against `fork()`, which Windows does not have, and that — not anything
## about the algorithm — is what kept the suite on POSIX.
##
## This module gives the child-process shape ONE spelling and TWO implementations:
##
##   * **POSIX: still `fork()`.** Deliberately. io-mon's producers ARE forked
##     children that inherit an attached handle and a live `MAP_SHARED` mapping,
##     so the fork path is load-bearing coverage on the platform that has it.
##     Rewriting these tests to `exec` a fresh child on Linux would have made the
##     port subtract coverage while appearing to add it.
##   * **Windows: re-execute this same test binary** with `--xproc-role <name>`,
##     and dispatch to the registered role. A spawned child shares no memory with
##     its parent at all, which is a STRICTLY HARSHER environment for the
##     property under test: it cannot accidentally pass by reading an inherited
##     copy of the parent's state.
##
## The cost of covering both is that a child body may no longer be a closure over
## the parent's locals — it is a registered `proc (args: seq[string])` and
## everything it needs arrives as strings. That is a real constraint, and it is
## the right one: a body that CANNOT be expressed that way is a body that depends
## on fork inheritance, which is exactly the class of test that has no Windows
## meaning and must be declared POSIX-only rather than quietly ported. See
## `posixOnlyProperty`.

import std/[os, tables]

when defined(windows):
  import std/[osproc, winlean]
  const PROCESS_TERMINATE = 0x0001'i32
  proc virtualAlloc(base: pointer; size: int; typ, protect: int32): pointer
    {.stdcall, dynlib: "kernel32", importc: "VirtualAlloc".}
  proc virtualFree(base: pointer; size: int; typ: int32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "VirtualFree".}
else:
  import std/posix

type
  ChildBody* = proc (args: seq[string]) {.nimcall.}

  Child* = object
    ## A live child process, whatever produced it.
    when defined(windows):
      p: Process
    else:
      pid: Pid

const RoleFlag = "--xproc-role"

var gRoles: Table[string, ChildBody]

proc registerChildRole*(name: string; body: ChildBody) =
  ## Register a child entry point. Call at module top level, BEFORE
  ## `xprocChildEntry()`.
  doAssert name notin gRoles, "duplicate xproc role: " & name
  gRoles[name] = body

proc xprocChildEntry*() =
  ## Call once at module top level, after every `registerChildRole` and BEFORE
  ## the first `suite`. In a spawned child this runs the requested role and
  ## exits; in the parent it returns immediately.
  ##
  ## On POSIX it is a no-op — children there are forked, not re-executed, so they
  ## never re-enter `main`.
  when defined(windows):
    let p = commandLineParams()
    if p.len >= 2 and p[0] == RoleFlag:
      let role = p[1]
      if role notin gRoles:
        stderr.writeLine "xproc: unknown role " & role
        quit(97)
      gRoles[role](p[2 .. ^1])
      quit(0)

proc exitChild*(code: int) {.noreturn.} =
  ## Leave a child process WITHOUT running exit handlers or flushing buffers the
  ## parent also owns. `_exit` on POSIX (a forked child shares the parent's stdio
  ## buffers, so `quit` would duplicate the parent's pending output); an ordinary
  ## `quit` on Windows, where the child shares nothing.
  when defined(windows):
    quit(code)
  else:
    exitnow(cint(code))

proc startChild*(role: string; args: varargs[string, `$`]): Child =
  ## Run the registered role `role` in a new process. Returns immediately.
  doAssert role in gRoles, "unregistered xproc role: " & role
  var a: seq[string] = @[]
  for x in args: a.add x
  when defined(windows):
    result.p = startProcess(getAppFilename(), args = @[RoleFlag, role] & a,
      options = {poParentStreams})
  else:
    let pid = fork()
    doAssert pid >= 0, "fork failed"
    if pid == 0:
      gRoles[role](a)
      exitChild(0)
    result.pid = pid

proc waitChild*(c: var Child): int =
  ## Wait for the child and return its EXIT STATUS. A child destroyed by
  ## `killChild` reports `KilledExitStatus` on both platforms; a child that ran
  ## to completion reports whatever it passed to `exitChild`.
  when defined(windows):
    result = c.p.waitForExit()
    c.p.close()
  else:
    var st: cint
    if waitpid(c.pid, st, 0) != c.pid: return -2
    if WIFEXITED(st): return int(WEXITSTATUS(st))
    if WIFSIGNALED(st): return 128 + int(WTERMSIG(st))
    return -1

const KilledExitStatus* = 137
  ## What `waitChild` reports for a child that `killChild` destroyed. POSIX has
  ## no exit status for "killed by a signal", so `waitChild` synthesises the
  ## conventional 128 + SIGKILL; Win32 has no signals, so `killChild` passes the
  ## same number to `TerminateProcess` as the exit code. One number on both
  ## platforms, and it is not 0, so "the victim ran to completion" and "the
  ## victim was killed where we wanted it" stay distinguishable.

proc killChild*(c: var Child) =
  ## Terminate the child UNCONDITIONALLY and uncleanly — `SIGKILL` on POSIX,
  ## `TerminateProcess` on Windows. Both leave the shard files exactly as the
  ## child left them, with no unwind, no destructor and no detach, which is the
  ## point: it is the crash the fault-injection battery needs to simulate.
  ##
  ## Neither is catchable by the victim, so neither can run a cleanup the real
  ## crash would not have run. `terminate()` is deliberately NOT used on Windows:
  ## it hardcodes its own exit code, and this needs `KilledExitStatus`.
  when defined(windows):
    let h = openProcess(PROCESS_TERMINATE, 0, int32(c.p.processID))
    doAssert h != Handle(0), "OpenProcess(PROCESS_TERMINATE) failed"
    doAssert terminateProcess(h, KilledExitStatus) != 0, "TerminateProcess failed"
    discard closeHandle(h)
  else:
    discard kill(c.pid, SIGKILL)

proc terminateSelf*() {.gcsafe, raises: [].} =
  ## Destroy THIS process as abruptly as the platform allows, from inside a
  ## schedule hook: `SIGKILL` to self on POSIX, `TerminateProcess` on its own
  ## handle on Win32. Neither runs an exit handler, flushes a buffer or unwinds,
  ## which is the point — the crash-atomicity cases need the process to stop
  ## between two stores with nothing in between.
  ##
  ## `{.gcsafe, raises: [].}` because the callers are `ScheduleHook`s.
  when defined(windows):
    discard terminateProcess(getCurrentProcess(), KilledExitStatus)
  else:
    discard kill(getpid(), SIGKILL)

# ---------------------------------------------------------------------------
# A map base of our choosing, for the position-independence test
# ---------------------------------------------------------------------------

proc reserveMapBase*(size: int): pointer =
  ## Find an address where a shard of `size` bytes can legally be mapped, so the
  ## test can force a mapping to a base THE TEST picked rather than one the
  ## kernel picked — which is how §4.5(b) shows the segment holds offsets only.
  ##
  ## POSIX: reserve it with an anonymous `PROT_NONE` mapping. `MAP_FIXED` then
  ## replaces the reservation atomically, so nothing else can take the address in
  ## between.
  ##
  ## Win32: `MapViewOfFileEx` requires the target range to be FREE, not merely
  ## reserved, so the reservation is made and then immediately released — the
  ## standard way to have the allocator choose an address on the 64 KiB
  ## granularity that the subsequent map then claims. There is a theoretical
  ## window in which another thread could take it; this is a single-threaded test
  ## driver, and a lost race would fail loudly (the map returns nil and
  ## `available` is false) rather than pass weakly.
  when defined(windows):
    const
      MEM_RESERVE = 0x2000'i32
      MEM_RELEASE = 0x8000'i32
      PAGE_NOACCESS = 0x01'i32
    let p = virtualAlloc(nil, size, MEM_RESERVE, PAGE_NOACCESS)
    if p == nil: return nil
    if virtualFree(p, 0, MEM_RELEASE) == 0: return nil
    p
  else:
    let p = mmap(nil, size, PROT_NONE, MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    if p == MAP_FAILED: return nil
    p

proc childPid*(c: Child): uint64 =
  when defined(windows): uint64(c.p.processID)
  else: uint64(c.pid)

# ---------------------------------------------------------------------------
# Properties that genuinely do not exist on this platform
# ---------------------------------------------------------------------------

var gNotApplicable*: seq[string] = @[]

proc notApplicableHere*(name, why: string) =
  ## Declare that `name` asserts a property of POSIX PROCESS SEMANTICS that has
  ## no Windows counterpart, and record it LOUDLY.
  ##
  ## THIS IS NOT A SKIP AND MUST NEVER BE USED AS ONE, and the call shape is
  ## chosen so it cannot become one by accident. The caller wraps the whole
  ## `test` block in `when defined(windows): notApplicableHere(..) else: test
  ## ...`, so on Windows the case is NOT REGISTERED WITH unittest at all. Had it
  ## stayed a registered `test` whose body merely printed this line, unittest
  ## would have reported `[OK]` for a case that asserted nothing — a fake pass
  ## that also keeps the OK count looking right. Instead the OK count DROPS,
  ## which is the honest signal, and this line plus `reportNotApplicable` says
  ## exactly which property is missing and why.
  echo "  [NOT-APPLICABLE-ON-THIS-PLATFORM] ", name
  echo "      reason: ", why
  gNotApplicable.add name

proc reportNotApplicable*() =
  ## Print the not-applicable roll-up. Call at the END of a test module that uses
  ## `posixOnlyProperty`, so the count is impossible to miss in the log.
  if gNotApplicable.len > 0:
    echo ""
    echo "[PLATFORM] ", gNotApplicable.len,
      " POSIX-process-semantics propert", (if gNotApplicable.len == 1: "y" else: "ies"),
      " have no Windows counterpart and were NOT asserted here:"
    for n in gNotApplicable: echo "    - ", n
    echo "[PLATFORM] They ARE asserted on Linux and macOS by this same file."

# ---------------------------------------------------------------------------
# Small portability helpers the suite needs in more than one file
# ---------------------------------------------------------------------------

proc ownPid*(): int =
  ## `getpid()` without dragging `std/posix` into a test module.
  int(getCurrentProcessId())

proc freshTestDir*(prefix, tag: string; ctr: var int): string =
  inc ctr
  result = getTempDir() / (prefix & "-" & tag & "-" & $ownPid() & "-" & $ctr)
  removeDir(result)
  createDir(result)
