## Real mappings, threads, subprocess death and compiler checks. No mocks.
## A test-only boundary hook drives races that cannot be scheduled reliably
## from outside the atomics; the production C algorithm remains unchanged.
import std/[atomics, os, osproc, strutils, times, unittest]
import shm_gset
import shm_gset/[transport, generation_publisher, platform]
import helpers/generation_policy
import ./xproc
when not defined(windows): import std/posix

static: doAssert scheduleHooksEnabled

var tmpCtr = 0
proc freshDir(tag: string): string = freshTestDir("gset-publisher", tag, tmpCtr)
proc awaitFile(path: string) =
  let until = epochTime() + 10
  while not fileExists(path):
    doAssert epochTime() < until, "timed out: " & path
    sleep(1)

proc markedChild(args: seq[string]) =
  var storage: PreparedGenerationPublisher
  var owner = openGenerationPublisher(args[0], TestGenerationPolicy, 0, storage)
  doAssert owner.available
  doAssert publishPreparedGeneration(addr storage) == gpsPublished
  writeFile(args[1], "published")
  # Keep the owner alive. The parent kills us before close or destruction.
  while true: sleep(10)

registerChildRole("markedChild", markedChild)
xprocChildEntry()

var hookStorage: ptr PreparedGenerationPublisher
var hookRaw: ptr ShmGSetT[TestGenerationPolicy]
var hookMode: int
var arrived, releaseHook: Atomic[int]
var closeSawDisarmed, closeSawRegistered: bool
proc boundaryHook(point: cint) {.cdecl, raises: [], gcsafe.} =
  {.cast(raises: []), cast(gcsafe).}:
    if point == 0 and hookMode == 1:
      arrived.store(1, moRelease)
      while releaseHook.load(moAcquire) == 0: yieldThread()
    if point == 1 and hookMode in [2, 3]:
      # Deliberately violate production quiescence at the actual CAS boundary.
      # This is a monotonicity test, not permission to recycle a live owner.
      let mode = hookMode
      hookMode = 0
      hookRaw[].forceGenerationForTest(2)
      if mode == 3: discard hookRaw[].controlWordBumpTo(0, 2)
    if point == 2 and hookMode == 4:
      closeSawDisarmed = publishPreparedGeneration(hookStorage) == gpsUnavailable
      closeSawRegistered = hookRaw[].attachedProducers == 1

var racePath: string
var raceStorage: PreparedGenerationPublisher
var raceStatus: PublisherPrepareStatus
proc openingThread() {.thread.} =
  {.cast(gcsafe).}:
    var owner = openGenerationPublisher(racePath, TestGenerationPolicy, 0, raceStorage)
    raceStatus = owner.prepareStatus
    doAssert owner.available
    while releaseHook.load(moAcquire) < 2: yieldThread()

suite "generation publication ownership and lifecycle":
  test "typed transport retains identity and rejects policy skew both ways":
    let dir = freshDir("typed")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    check host.available
    check host.readPolicyWord(0) == PolicyWordRead(status: pwrRead, generation: 1, value: 0)
    check host.readPolicyWord(-1).status == pwrInvalidWord
    check host.readPolicyWord(1).status == pwrInvalidWord
    var p = attachProducerT(host.path0, TestGenerationPolicy, maxElementBytes = 2)
    check p.available
    check p.emit([1'u8, 2]) == emInserted
    check p.emit([1'u8, 2]) == emExists
    check p.emit([1'u8, 2, 3]) == emOversize
    check host.snapshot() == @[@[1'u8, 2]]
    p.detach()
    var old = attachProducer(host.path0)
    check not old.available
    check old.attachFailure == afKeyDisciplineSkew
    var defaultHost = startHost(dir, "default")
    defer: defaultHost.finish()
    var wrong = attachProducerT(defaultHost.path0, TestGenerationPolicy)
    check not wrong.available
    check wrong.attachFailure == afKeyDisciplineSkew
    check host.reset("next") == rsReset
    check host.generation == 2
    check host.runId == "next"
    check host.snapshot().len == 0
    host.finish()
    check host.readPolicyWord(0).status == pwrUnavailable

  test "owner is independent, move-only, and destructor disarms":
    let dir = freshDir("move")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    var storage: PreparedGenerationPublisher
    check publishPreparedGeneration(addr storage) == gpsUnavailable
    block:
      var source = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
      check source.available
      check not compiles(source.emit([1'u8]))
      check not compiles(source.attachment)
      check not compiles(source.shards0Base())
      var ordinary = attachProducerT(host.path0, TestGenerationPolicy)
      check host.attachedProducers == 2
      var alias = ordinary
      alias.detach()
      # Ordinary producers retain their existing alias/copy contract: closing
      # one invalidates that view's copies. Never use/detach ordinary again.
      # The independently attached publisher must remain usable.
      check host.attachedProducers == 1
      var moved = move(source)
      source.close()
      check not source.available
      check moved.available
      check publishPreparedGeneration(addr storage) == gpsPublished
      check publishPreparedGeneration(addr storage) == gpsAlreadyPublished
      check host.readPolicyWord(0).value == host.generation
      check host.reset("refused") == rsBusyProducers
    check host.attachedProducers == 0
    check publishPreparedGeneration(addr storage) == gpsUnavailable
    check host.reset("next") == rsReset
    check host.readPolicyWord(0).value == 1 # reset never clears policy metadata
    check host.readPolicyWord(0).generation == 2
    var reopened = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
    check reopened.available
    check publishPreparedGeneration(addr storage) == gpsPublished
    check host.readPolicyWord(0).value == 2
    reopened.close()
    reopened.close()

  test "real compiler refuses copy and accepts the move control":
    let root = currentSourcePath().parentDir.parentDir
    let probe = root / "tests/helpers/publisher_copy_probe.nim"
    proc compileProbe(flag: string): tuple[output: string, exitCode: int] =
      execCmdEx("nim c --hints:off --threads:on --path:" & quoteShell(root / "src") &
        " --path:" & quoteShell(root / "tests/helpers") & " " & flag &
        " -o:" & quoteShell(getTempDir() / "gset-publisher-copy-probe") &
        " " & quoteShell(probe))
    let copied = compileProbe("")
    check copied.exitCode != 0
    check "'=copy' is not available" in copied.output
    let moved = compileProbe("-d:movePublisher")
    check moved.exitCode == 0

  test "live binding refusal leaves the first owner intact and close releases it":
    let dir = freshDir("binding")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    var storage: PreparedGenerationPublisher
    var first = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
    var second = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
    check second.prepareStatus == ppsStorageInUse
    second.close()
    check host.attachedProducers == 1
    check publishPreparedGeneration(addr storage) == gpsPublished
    first.close()
    var third = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
    check third.available
    third.close()
    check host.attachedProducers == 0

  test "racing open cannot overwrite a preparing binding":
    let dir = freshDir("racing")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    racePath = host.path0
    arrived.store(0)
    releaseHook.store(0)
    hookMode = 1
    generationPublisherTestHook = boundaryHook
    var worker: Thread[void]
    createThread(worker, openingThread)
    let until = epochTime() + 10
    while arrived.load(moAcquire) == 0:
      doAssert epochTime() < until
      yieldThread()
    var refused = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, raceStorage)
    check refused.prepareStatus == ppsStorageInUse
    check publishPreparedGeneration(addr raceStorage) == gpsUnavailable
    releaseHook.store(1, moRelease)
    # readiness is observed only through the production acquire-load.
    var status = gpsUnavailable
    while status == gpsUnavailable:
      doAssert epochTime() < until
      status = publishPreparedGeneration(addr raceStorage)
    check status == gpsPublished
    releaseHook.store(2, moRelease)
    joinThread(worker)
    generationPublisherTestHook = nil
    hookMode = 0
    check raceStatus == ppsReady
    check publishPreparedGeneration(addr raceStorage) == gpsUnavailable
    check host.attachedProducers == 0

  test "failed preparation releases storage, registration and mapping":
    let dir = freshDir("partial")
    defer: removeDir(dir)
    var raw = createSetT(dir, "test", "run", TestGenerationPolicy)
    defer: raw.detach()
    var storage: PreparedGenerationPublisher
    var missing = openGenerationPublisher(dir / "missing.shard0", TestGenerationPolicy, 0, storage)
    check missing.prepareStatus == ppsUnavailable
    check missing.attachFailure == afMissing
    var invalidWord = openGenerationPublisher(raw.path0, TestGenerationPolicy, 1, storage)
    check invalidWord.prepareStatus == ppsInvalidWord
    check raw.attachedProducers == 0
    raw.forceGenerationForTest(0)
    when defined(linux):
      let mappedBefore = readFile("/proc/self/maps").count(raw.path0)
      check mappedBefore == 1
    for attempt in 0 ..< 20:
      var invalidGeneration = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
      check invalidGeneration.prepareStatus == ppsInvalidState
    when defined(linux):
      check readFile("/proc/self/maps").count(raw.path0) == mappedBefore
    check raw.attachedProducers == 0
    check publishPreparedGeneration(addr storage) == gpsUnavailable
    raw.forceGenerationForTest(1)
    var valid = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
    check valid.available
    valid.close()
    check raw.attachedProducers == 0

  test "publisher policy skew is diagnosed in both directions without a leak":
    let dir = freshDir("publisher-skew")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    var otherHost = startHostT(dir, "other", OtherGenerationPolicy)
    defer: otherHost.finish()
    var storage: PreparedGenerationPublisher
    var old = openGenerationPublisher(host.path0, OtherGenerationPolicy, 0, storage)
    check old.prepareStatus == ppsUnavailable
    check old.attachFailure == afKeyDisciplineSkew
    var wrong = openGenerationPublisher(otherHost.path0, TestGenerationPolicy, 0, storage)
    check wrong.prepareStatus == ppsUnavailable
    check wrong.attachFailure == afKeyDisciplineSkew
    check host.attachedProducers == 0
    check otherHost.attachedProducers == 0
    var good = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
    check good.available
    check publishPreparedGeneration(addr storage) == gpsPublished
    good.close()

  test "move assignment closes the destination and preserves the moved binding":
    let dir = freshDir("move-assignment")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    var firstStorage, secondStorage: PreparedGenerationPublisher
    var source = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, firstStorage)
    var destination = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, secondStorage)
    check host.attachedProducers == 2
    destination = move(source)
    source.close()
    check host.attachedProducers == 1
    check publishPreparedGeneration(addr secondStorage) == gpsUnavailable
    check publishPreparedGeneration(addr firstStorage) == gpsPublished
    destination.close()
    check host.attachedProducers == 0
    check publishPreparedGeneration(addr firstStorage) == gpsUnavailable

  test "close disarms while its mapping and registration still exist":
    let dir = freshDir("close-order")
    defer: removeDir(dir)
    var raw = createSetT(dir, "test", "run", TestGenerationPolicy)
    defer: raw.detach()
    var storage: PreparedGenerationPublisher
    var owner = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
    hookRaw = addr raw
    hookStorage = addr storage
    hookMode = 4
    closeSawDisarmed = false
    closeSawRegistered = false
    generationPublisherTestHook = boundaryHook
    owner.close()
    generationPublisherTestHook = nil
    hookMode = 0
    check closeSawDisarmed
    check closeSawRegistered
    check raw.attachedProducers == 0
    check raw.reset("after-close") == rsReset

  test "gone stale invalid and exhausted states remain distinct":
    let dir = freshDir("states")
    defer: removeDir(dir)
    var raw = createSetT(dir, "test", "run", TestGenerationPolicy)
    defer: raw.detach()
    var storage: PreparedGenerationPublisher
    var owner = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
    check raw.reset("busy") == rsBusyProducers
    raw.markConsumerGone()
    check publishPreparedGeneration(addr storage) == gpsConsumerGone
    raw.forceGenerationForTest(2)
    check publishPreparedGeneration(addr storage) == gpsGenerationChanged
    owner.close()
    check raw.reset("rearmed") == rsReset
    var current = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
    discard raw.controlWordBumpTo(0, raw.generation + 1)
    check publishPreparedGeneration(addr storage) == gpsInvalidState
    current.close()
    raw.forceGenerationForTest(MaxGeneration)
    check raw.reset("wrap-refused") == rsGenerationExhausted
    check raw.generation == MaxGeneration

  test "delayed old-generation CAS neither erases nor claims a new mark":
    for mode in [2, 3]:
      let dir = freshDir("forced-reset")
      defer: removeDir(dir)
      var raw = createSetT(dir, "test", "run", TestGenerationPolicy)
      defer: raw.detach()
      var storage: PreparedGenerationPublisher
      var owner = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
      hookRaw = addr raw
      hookMode = mode
      generationPublisherTestHook = boundaryHook
      let status = publishPreparedGeneration(addr storage)
      generationPublisherTestHook = nil
      check raw.generation == 2
      check status == gpsGenerationChanged
      if mode == 2:
        check raw.controlWord(0) == 1 # ignored by generation 2
      else:
        check raw.controlWord(0) == 2 # never erased by the delayed CAS
      check publishPreparedGeneration(addr storage) == gpsGenerationChanged
      owner.close()

  test "independent mapping at a forced address publishes into the same shard":
    let dir = freshDir("position")
    defer: removeDir(dir)
    var raw = createSetT(dir, "test", "run", TestGenerationPolicy)
    defer: raw.detach()
    let want = reserveMapBase(int(getFileSize(raw.path0)))
    check want != nil
    check want != raw.shards0Base()
    setForcedNextMapBase(want)
    var storage: PreparedGenerationPublisher
    var owner = openGenerationPublisher(raw.path0, TestGenerationPolicy, 0, storage)
    check owner.available
    check owner.generationPublisherMappedAtForTest(want)
    check publishPreparedGeneration(addr storage) == gpsPublished
    check raw.controlWord(0) == 1
    raw.assertNoAbsolutePointers()
    check raw.snapshot().len == 0
    owner.close()

  test "consumer retains the mark after producer death without cleanup":
    let dir = freshDir("death")
    defer: removeDir(dir)
    var host = startHostT(dir, "run", TestGenerationPolicy)
    defer: host.finish()
    let ready = dir / "ready"
    var child = startChild("markedChild", host.path0, ready)
    awaitFile(ready)
    check host.attachedProducers == 1
    check host.reset("busy") == rsBusyProducers
    child.killChild()
    check child.waitChild() == KilledExitStatus
    check host.readPolicyWord(0).value == 1
    check host.snapshot().len == 0
    check host.reset("next") == rsReset
    check host.readPolicyWord(0) == PolicyWordRead(status: pwrRead, generation: 2, value: 1)

  when not defined(windows):
    test "private-fork reopen preserves parent registration and adds the child":
      let dir = freshDir("fork-reopen")
      defer: removeDir(dir)
      var host = startHostT(dir, "run", TestGenerationPolicy)
      defer: host.finish()
      var storage: PreparedGenerationPublisher
      var owner = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
      let child = fork()
      check child >= 0
      if child == 0:
        owner.close() # must not clear the inherited parent's slot
        doAssert host.attachedProducers == 1
        var own = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
        doAssert own.available
        doAssert host.attachedProducers == 2
        doAssert publishPreparedGeneration(addr storage) == gpsPublished
        writeFile(dir / "ready", "child registered")
        awaitFile(dir / "release")
        own.close()
        exitChild(0)
      awaitFile(dir / "ready")
      check host.attachedProducers == 2
      check host.reset("busy") == rsBusyProducers
      owner.close()
      check host.attachedProducers == 1
      check host.reset("child-busy") == rsBusyProducers
      writeFile(dir / "release", "done")
      var status: cint
      check waitpid(child, status, 0) == child
      check WIFEXITED(status) and WEXITSTATUS(status) == 0
      check host.attachedProducers == 0
      check host.reset("next") == rsReset

    test "inherited view is unregistered after its original producer dies":
      let dir = freshDir("fork-parent-death")
      defer: removeDir(dir)
      var host = startHostT(dir, "run", TestGenerationPolicy)
      defer: host.finish()
      let producer = fork()
      check producer >= 0
      if producer == 0:
        var storage: PreparedGenerationPublisher
        var owner = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
        doAssert owner.available
        let descendant = fork()
        doAssert descendant >= 0
        if descendant == 0:
          writeFile(dir / "inherited", "alive")
          awaitFile(dir / "reset-done")
          # No publication through this inherited view: a recycling consumer
          # must invalidate and reopen. Parent death did not register our PID.
          owner.close()
          var own = openGenerationPublisher(host.path0, TestGenerationPolicy, 0, storage)
          doAssert own.available
          doAssert publishPreparedGeneration(addr storage) == gpsPublished
          own.close()
          writeFile(dir / "done", "reopened")
          exitChild(0)
        awaitFile(dir / "inherited")
        exitChild(0) # no destructor, original PID's registry entry survives
      var status: cint
      check waitpid(producer, status, 0) == producer
      check WIFEXITED(status) and WEXITSTATUS(status) == 0
      awaitFile(dir / "inherited")
      check host.attachedProducers == 0
      check host.reset("next") == rsReset
      writeFile(dir / "reset-done", "generation 2")
      awaitFile(dir / "done")
      check host.readPolicyWord(0).value == 2
  else:
    notApplicableHere("private-fork reopen preserves parent registration and adds the child",
      "private address-space fork is a POSIX process operation")
    notApplicableHere("inherited view is unregistered after its original producer dies",
      "private address-space fork is a POSIX process operation")
