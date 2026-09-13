## Platform shim: the handful of OS primitives the shard chain is built on.
##
## The library's algorithm is entirely portable — it is offsets, C11 atomics and
## a file-backed shared mapping — so the only thing that was ever Linux/macOS
## specific was the SPELLING of a dozen syscalls. This module gives them one
## spelling, POSIX-shaped, implemented over `mmap` on POSIX and over
## `CreateFileMappingW` / `MapViewOfFileEx` on Win32, so `shm_gset.nim` reads the
## same on every platform and the port is additive rather than a fork.
##
## ============================================================================
## THE ONE PLACE POSIX AND WIN32 DISAGREE, AND WHY THE CONTRACT SURVIVES
## ============================================================================
##
## The durability contract is "PERSISTS == THE FILE EXISTS", decoupled from the
## mapping count (design spec §4.3.2). On POSIX that is free: `unlink` drops the
## name while every existing mapping stays live and coherent, and `rename` is
## atomic.
##
## Win32 is widely believed to forbid this — "you cannot delete or rename over a
## file while a view of it is mapped". That is TRUE ONLY IF SOME OPENER WITHHELD
## `FILE_SHARE_DELETE`, which is the default in most code and is why the belief
## is widespread. It is not a property of the mapping. Measured on this port
## (Windows 11, build 26200) and kept measured by
## `tests/test_shm_gset_win32.nim`:
##
##   * `DeleteFileW` on a file with a LIVE MAPPED VIEW succeeds, the name is gone
##     immediately (`fileExists` is false in the same thread), and the view stays
##     fully readable AND writable afterwards — POSIX `unlink` semantics exactly.
##   * The same call with any handle open WITHOUT `FILE_SHARE_DELETE` fails with
##     ERROR_SHARING_VIOLATION (32). That is the whole difference.
##   * `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` over a mapped destination
##     succeeds under the same condition.
##
## So every open below passes `FILE_SHARE_READ or FILE_SHARE_WRITE or
## FILE_SHARE_DELETE`, without exception, and the contract holds identically on
## both platforms rather than being weakened to suit one. That share mode is
## load-bearing, not defensive: drop `FILE_SHARE_DELETE` and the reaper stops
## being able to collect a chain it has already opened, which is exactly the
## sequence `reapStaleSegmentsDetailed` performs — open the anchor, lock it, then
## unlink the whole chain INCLUDING that anchor while the handle is still open.
##
## The one thing Win32 really does forbid is SHRINKING a file that is mapped
## (`SetEndOfFile` -> ERROR_USER_MAPPED_FILE, 1224). This library never shrinks a
## file at all: `setFileSize` is called exactly once per shard, on a freshly
## created temp file, BEFORE it is ever mapped. Growth by sharding means a shard
## file's size is immutable for its whole life, so the restriction is not one
## this design can reach.
##
## ============================================================================
## PRIMITIVE MAPPING
## ============================================================================
##
## ==========================================  ==========================================
## POSIX                                       Win32
## ==========================================  ==========================================
## `open(p, O_RDWR|O_CREAT|O_EXCL, 0600)`      `CreateFileW(.., CREATE_NEW)`
## `open(p, O_RDWR)` / `O_RDONLY`              `CreateFileW(.., OPEN_EXISTING)`
## `ftruncate(fd, n)`                          `SetFilePointerEx` + `SetEndOfFile`
## `mmap(nil, n, RW, MAP_SHARED, fd, 0)`       `CreateFileMappingW` + `MapViewOfFileEx`
## `mmap(a, .., MAP_FIXED, ..)` (test-only)    `MapViewOfFileEx(.., a)`
## `munmap(p, n)`                              `UnmapViewOfFile(p)` (length implicit)
## `close(fd)`                                 `CloseHandle(h)`
## `link(tmp, final)` (exclusive publish)      `CreateHardLinkW`, else `MoveFileExW`
## `unlink(p)`                                 `DeleteFileW(p)`
## `flock(fd, LOCK_EX|LOCK_NB)`                `LockFileEx(EXCLUSIVE|FAIL_IMMEDIATELY)`
## `kill(pid, 0)` / `ESRCH`                    `OpenProcess` + `WaitForSingleObject(h, 0)`
## `sched_yield()`                             `SwitchToThread()`
## `/proc/sys/kernel/random/boot_id`           `NtQuerySystemInformation` `BootTime`
## ==========================================  ==========================================
##
## The SECTION handle (`CreateFileMappingW`) is deliberately not kept: Win32
## documents that the system holds the underlying file open until the last VIEW
## is unmapped, so a view outlives both the section handle and the file handle.
## That is what lets `openShard` close its descriptor immediately after mapping
## on both platforms — the behaviour commit 360bfc1 introduced for POSIX — and it
## is measured rather than assumed (`a view outlives both handles` in the Win32
## suite).

const shmGSetPlatformSupported* = defined(linux) or defined(macosx) or
                                  defined(windows)

when shmGSetPlatformSupported:
  import std/times

  type ShmFile* = distinct int
    ## A POSIX file descriptor or a Win32 `HANDLE`. Both spell "invalid" as -1.

  const InvalidShmFile* = ShmFile(-1)

  proc `==`*(a, b: ShmFile): bool {.borrow.}
  proc isValid*(f: ShmFile): bool {.inline.} = f != InvalidShmFile

when defined(windows):
  import std/[os, winlean]

  const
    FILE_SHARE_ALL = FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE
      ## EVERY open in this library uses this share mode. See the module doc:
      ## `FILE_SHARE_DELETE` is what makes "persists == the file exists" mean the
      ## same thing here as it does on POSIX.
    WinFileAttrNormal = 0x80'i32
    FILE_MAP_RW = FILE_MAP_READ or FILE_MAP_WRITE
    WinErrFileExists = 80'i32
    WinErrAlreadyExists = 183'i32
    LOCKFILE_FAIL_IMMEDIATELY = 0x1'i32
    LOCKFILE_EXCLUSIVE_LOCK = 0x2'i32
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000'i32
    WinWaitTimeout = 0x102'i32
    WinErrAccessDenied = 5'i32
    WinWaitFailed = -1'i32

  proc setFilePointerEx(h: Handle; dist: int64; newPos: ptr int64;
      meth: int32): WINBOOL {.stdcall, dynlib: "kernel32",
      importc: "SetFilePointerEx".}
  proc createHardLinkW(newName, existing: WideCString;
      sa: pointer): WINBOOL {.stdcall, dynlib: "kernel32",
      importc: "CreateHardLinkW".}
  proc lockFileEx(h: Handle; flags, reserved: int32; lo, hi: int32;
      ov: pointer): WINBOOL {.stdcall, dynlib: "kernel32",
      importc: "LockFileEx".}
  proc unlockFileEx(h: Handle; reserved: int32; lo, hi: int32;
      ov: pointer): WINBOOL {.stdcall, dynlib: "kernel32",
      importc: "UnlockFileEx".}
  proc switchToThread(): WINBOOL {.stdcall, dynlib: "kernel32",
      importc: "SwitchToThread".}
  proc getTickCount64(): uint64 {.stdcall, dynlib: "kernel32",
      importc: "GetTickCount64".}

  type SystemTimeOfDayInformation = object
    bootTime: int64
    currentTime: int64
    timeZoneBias: int64
    timeZoneId: uint32
    reserved: uint32
    bootTimeBias: uint64
    sleepTimeBias: uint64

  proc ntQuerySystemInformation(cls: int32; buf: pointer; len: uint32;
      ret: ptr uint32): int32 {.stdcall, dynlib: "ntdll.dll",
      importc: "NtQuerySystemInformation".}

  # --- open / close ---------------------------------------------------------

  proc openNewExclusive*(path: string): ShmFile =
    ## `open(path, O_RDWR|O_CREAT|O_EXCL, 0600)`. Fails if the name exists, which
    ## is the arbitration the temp-name retry loop and the double-grow loser both
    ## rely on.
    ShmFile(createFileW(newWideCString(path), GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_ALL, nil, CREATE_NEW, WinFileAttrNormal, Handle(0)))

  proc openReadWrite*(path: string): ShmFile =
    ShmFile(createFileW(newWideCString(path), GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_ALL, nil, OPEN_EXISTING, WinFileAttrNormal, Handle(0)))

  proc openReadOnly*(path: string): ShmFile =
    ShmFile(createFileW(newWideCString(path), GENERIC_READ,
      FILE_SHARE_ALL, nil, OPEN_EXISTING, WinFileAttrNormal, Handle(0)))

  proc closeFile*(f: ShmFile) =
    if f.isValid: discard closeHandle(Handle(f))

  proc lastOpenFailedBecauseItExists*(): bool =
    ## The `EEXIST` test the temp-name retry loop makes: a COLLIDING NAME must be
    ## retried under a fresh name; any other error is a real failure.
    let e = getLastError()
    e == WinErrFileExists or e == WinErrAlreadyExists

  # --- size / read ----------------------------------------------------------

  proc setFileSize*(f: ShmFile; size: int): bool =
    ## `ftruncate`. Only ever called on a freshly created, NOT-YET-MAPPED file —
    ## see the module doc on ERROR_USER_MAPPED_FILE.
    var np: int64
    if setFilePointerEx(Handle(f), int64(size), addr np, 0) == 0: return false
    setEndOfFile(Handle(f)) != 0

  proc readSome*(f: ShmFile; buf: pointer; n: int): int =
    ## One sequential `read`: bytes read, 0 at EOF, -1 on error.
    var got: int32 = 0
    if readFile(Handle(f), buf, int32(n), addr got, nil) == 0: return -1
    int(got)

  proc seekToStart*(f: ShmFile): bool =
    ## Rewind the descriptor so a caller can read a file it already holds open
    ## (and, in the reaper's case, already holds LOCKED) from the top.
    var np: int64
    setFilePointerEx(Handle(f), 0, addr np, 0) != 0

  # --- mapping --------------------------------------------------------------

  proc mapShared*(f: ShmFile; size: int; want: pointer = nil): pointer =
    ## `mmap(want, size, PROT_READ|PROT_WRITE, MAP_SHARED[|MAP_FIXED], f, 0)`.
    ##
    ## `want` is the test-only position-independence hint. Win32 requires it to
    ## be on the 64 KiB ALLOCATION GRANULARITY, where POSIX needs only page
    ## alignment — see `mapBaseAlignment`, which lets the test pick a legal
    ## address on either platform instead of hard-coding a POSIX-legal one.
    let m = createFileMappingW(Handle(f), nil, PAGE_READWRITE,
      int32(uint64(size) shr 32), int32(uint64(size) and 0xFFFF_FFFF'u64), nil)
    if m == Handle(0): return nil
    result = mapViewOfFileEx(m, FILE_MAP_RW, 0, 0, WinSizeT(size), want)
    # The view holds its own reference to the section and to the file, so the
    # section handle is dropped immediately — nothing needs to carry it around.
    discard closeHandle(m)

  proc unmapShared*(p: pointer; size: int) =
    ## `munmap`. Win32 derives the length from the view itself, so `size` is
    ## accepted and ignored; the call sites stay identical on both platforms.
    discard size
    if p != nil: discard unmapViewOfFile(p)

  const mapBaseAlignment* = 65536
    ## Win32 allocation granularity: `MapViewOfFileEx` REJECTS a base that is
    ## merely page-aligned (measured: ERROR_INVALID_ADDRESS, 1132).

  # --- publish / unlink -----------------------------------------------------

  proc linkExclusive*(existing, newName: string): bool =
    ## POSIX `link(existing, newName)`: publish under the final name, FAILING if
    ## that name is already taken (the double-grow loser's arbitration).
    ##
    ## `CreateHardLinkW` is the exact analogue and is tried first, so the
    ## intermediate state matches POSIX byte for byte — both names exist until
    ## the caller drops the temp. It needs a filesystem with hard links; where
    ## there is none (exFAT, some network redirectors) it fails with something
    ## other than ALREADY_EXISTS, and a no-replace `MoveFileExW` — also atomic,
    ## also failing with ALREADY_EXISTS when the name is taken — publishes
    ## instead. The caller's unconditional `unlink(tmp)` is then a harmless
    ## no-op. Falling back rather than failing matters: a growth failure here is
    ## SIGNALLED saturation, which grades a capture incomplete.
    if createHardLinkW(newWideCString(newName), newWideCString(existing),
        nil) != 0:
      return true
    if getLastError() == WinErrAlreadyExists: return false
    moveFileExW(newWideCString(existing), newWideCString(newName), 0) != 0

  proc unlinkPath*(path: string): bool {.discardable.} =
    ## `unlink`. Succeeds while the file is MAPPED — see the module doc.
    deleteFileW(newWideCString(path)) != 0

  # --- advisory whole-file lock --------------------------------------------

  proc tryLockExclusive*(f: ShmFile): bool =
    ## `flock(fd, LOCK_EX|LOCK_NB)`. Like `flock`, the lock is released when the
    ## handle closes, which is all the reaper relies on.
    ##
    ## ONE SEMANTIC DIFFERENCE, AND IT BITES: `flock` is ADVISORY and `LockFileEx`
    ## is MANDATORY. A second handle reading a range this lock covers is refused
    ## here (ERROR_LOCK_VIOLATION) where POSIX would allow it, which is why the
    ## reaper reads shard0's header through the descriptor it already holds
    ## rather than re-opening the file — see `readAnchorRunId`. The range is the
    ## whole file, matching what `flock` means, and the reaper only ever takes it
    ## on a chain it has ALREADY judged stale, so no live mapping is under it.
    var ov: array[4, uint64]     # OVERLAPPED, zeroed: offset 0
    lockFileEx(Handle(f), LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY,
      0, -1, -1, addr ov) != 0

  proc unlockExclusive*(f: ShmFile): bool {.discardable.} =
    ## `flock(fd, LOCK_UN)`. Releasing explicitly is not needed by the library
    ## (closing the handle does it), but a test that wants to show the lock is
    ## what was holding the reaper off needs to drop it without closing.
    var ov: array[4, uint64]
    unlockFileEx(Handle(f), 0, -1, -1, addr ov) != 0

  # --- processes ------------------------------------------------------------

  proc processAlive*(pid: uint64): bool =
    ## `kill(pid, 0) == 0 or errno != ESRCH`.
    ##
    ## `WaitForSingleObject(h, 0)` is the PRIMARY test rather than
    ## `GetExitCodeProcess`, because a process may legitimately exit with code
    ## 259, which is indistinguishable from `STILL_ACTIVE`. The wait has no such
    ## ambiguity: a process object is signalled if and only if the process has
    ## exited.
    ##
    ## `SYNCHRONIZE` IS PART OF THE ACCESS MASK AND MUST BE. This was got wrong
    ## once here and the symptom was badly misleading rather than obviously
    ## broken: `PROCESS_QUERY_LIMITED_INFORMATION` alone opens the handle
    ## perfectly happily, and then `WaitForSingleObject` on it returns
    ## `WAIT_FAILED` (-1) — which is not `WAIT_TIMEOUT`, so EVERY pid, including
    ## this process's own, reported DEAD. That turns the reaper's staleness rule
    ## from "collect chains whose owner has gone" into "collect everything", and
    ## the two tests that caught it were `a dead-owner run is reaped; a
    ## live-owner run is left alone` and `cross-app isolation`, both of which
    ## failed on the LIVE half while the dead half still passed.
    ##
    ## The `GetExitCodeProcess` fallback is kept for the case where SYNCHRONIZE
    ## is refused but the limited query is granted, which can happen across a
    ## privilege boundary; there the 259 ambiguity is accepted because the only
    ## alternative is no answer at all.
    if pid == 0: return false
    let h = openProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION, 0,
      int32(pid))
    if h == Handle(0):
      # Conservative in the same direction as `kill`'s EPERM: a pid we are not
      # allowed to open EXISTS, so report it alive. Only "no such process"
      # reports dead.
      return getLastError() == WinErrAccessDenied
    let w = waitForSingleObject(h, 0)
    if w == WinWaitFailed:
      var code: int32 = 0
      result = getExitCodeProcess(h, code) != 0 and code == STILL_ACTIVE
    else:
      result = w == WinWaitTimeout
    discard closeHandle(h)

  proc currentPid*(): uint64 {.inline.} = uint64(getCurrentProcessId())

  proc yieldThread*() {.inline.} = discard switchToThread()

  # --- boot identity --------------------------------------------------------

  proc platformBootId*(): uint64 =
    ## See `bootId` in shm_gset.nim for WHY this must be constant for the life of
    ## a boot. The macOS incident recorded there — a wall-clock fallback made two
    ## processes one second apart disagree about the boot, so every attach judged
    ## a live chain stale and the set silently read empty — is the exact failure
    ## this avoids on Windows.
    ##
    ## `NtQuerySystemInformation(SystemTimeOfDayInformation).BootTime` is the
    ## authoritative Win32 answer: a 100 ns FILETIME fixed at boot, the value the
    ## system's own uptime is derived from. Measured constant across repeated
    ## processes seconds apart; the wall clock is not.
    ##
    ## `GetTickCount64` alone is NOT usable: it is a DURATION, so two processes
    ## started a second apart read different values for one boot — the macOS bug
    ## again. Subtracting it from the wall clock is the fallback below, kept only
    ## for a host where ntdll's query is unavailable; there a chain is recreated
    ## more often than it needs to be, which costs a warm-up and never
    ## correctness.
    var info: SystemTimeOfDayInformation
    var retLen: uint32 = 0
    if ntQuerySystemInformation(3'i32, addr info, uint32(sizeof(info)),
        addr retLen) == 0 and info.bootTime != 0:
      return uint64(info.bootTime) or 1'u64
    let ft = uint64(getTime().toWinTime())   # 100 ns ticks, wall clock
    let up = getTickCount64() * 10_000'u64
    if ft > up: return (ft - up) or 1'u64
    (uint64(getTime().toUnix()) or 1'u64)

elif shmGSetPlatformSupported:
  import std/posix

  proc flockRaw(fd: cint; op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}
  const
    LOCK_EX = cint(2)
    LOCK_NB = cint(4)
    LOCK_UN = cint(8)

  when defined(macosx):
    proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
        newp: pointer; newlen: csize_t): cint
      {.importc, header: "<sys/sysctl.h>".}

  proc openNewExclusive*(path: string): ShmFile =
    ShmFile(open(path.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600))

  proc openReadWrite*(path: string): ShmFile =
    ShmFile(open(path.cstring, O_RDWR))

  proc openReadOnly*(path: string): ShmFile =
    ShmFile(open(path.cstring, O_RDONLY))

  proc closeFile*(f: ShmFile) =
    if f.isValid: discard close(cint(f))

  proc lastOpenFailedBecauseItExists*(): bool = errno == EEXIST

  proc setFileSize*(f: ShmFile; size: int): bool =
    ftruncate(cint(f), Off(size)) == 0

  proc readSome*(f: ShmFile; buf: pointer; n: int): int =
    read(cint(f), buf, n)

  proc seekToStart*(f: ShmFile): bool =
    lseek(cint(f), Off(0), SEEK_SET) == Off(0)

  proc mapShared*(f: ShmFile; size: int; want: pointer = nil): pointer =
    var flags = MAP_SHARED
    if want != nil: flags = flags or MAP_FIXED
    let p = mmap(want, size, PROT_READ or PROT_WRITE, flags, cint(f), 0)
    if p == MAP_FAILED: return nil
    p

  proc unmapShared*(p: pointer; size: int) =
    if p != nil: discard munmap(p, size)

  const mapBaseAlignment* = 4096
    ## POSIX `MAP_FIXED` needs only page alignment.

  proc linkExclusive*(existing, newName: string): bool =
    link(existing.cstring, newName.cstring) == 0

  proc unlinkPath*(path: string): bool {.discardable.} =
    unlink(path.cstring) == 0

  proc tryLockExclusive*(f: ShmFile): bool =
    flockRaw(cint(f), LOCK_EX or LOCK_NB) == 0

  proc unlockExclusive*(f: ShmFile): bool {.discardable.} =
    flockRaw(cint(f), LOCK_UN) == 0

  proc processAlive*(pid: uint64): bool =
    if pid == 0: return false
    if kill(Pid(pid), cint(0)) == 0: return true
    errno != ESRCH

  proc currentPid*(): uint64 {.inline.} = uint64(getpid())

  proc yieldThread*() {.inline.} = discard sched_yield()

  proc platformBootId*(): uint64 =
    when defined(linux):
      try:
        let raw = readFile("/proc/sys/kernel/random/boot_id")
        var h: uint64 = 1469598103934665603'u64
        for ch in raw:
          if ch != '-' and ch != '\n':
            h = (h xor uint64(ord(ch))) * 1099511628211'u64
        return (h or 1'u64)
      except CatchableError: discard
    elif defined(macosx):
      var tv: Timeval
      var size = csize_t(sizeof(tv))
      if sysctlbyname("kern.boottime", addr tv, addr size, nil, 0) == 0 and
          size == csize_t(sizeof(tv)):
        let secs = uint64(tv.tv_sec)
        let usecs = uint64(tv.tv_usec)
        if secs != 0'u64:
          return ((secs * 1_000_000'u64 + usecs) or 1'u64)
    (uint64(getTime().toUnix()) or 1'u64)
