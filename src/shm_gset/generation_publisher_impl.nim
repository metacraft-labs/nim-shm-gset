# Included by shm_gset.nim so pointer preparation stays beside the private
# mapping representation. There is deliberately no raw-mapping accessor on
# the owner, and no public prepare-from-pointers operation.
import std/os as publisherOs

const publisherHeader = publisherOs.parentDir(currentSourcePath()) /
  "generation_publisher.h"
const publisherInternalHeader = publisherOs.parentDir(currentSourcePath()) /
  "generation_publisher_internal.h"
{.compile: "generation_publisher.c".}

when defined(shmGSetScheduleHooks):
  {.passC: "-DSHM_GSET_PUBLISHER_TEST_HOOKS".}
  var generationPublisherTestHook* {.importc: "shm_gset_publisher_test_hook",
    header: publisherInternalHeader.}: proc(point: cint) {.cdecl, raises: [], gcsafe.}

type
  PreparedGenerationPublisher* {.importc:
      "shm_gset_prepared_generation_publisher", header: publisherHeader,
      bycopy.} = object
    ## Caller-owned C POD. Nim's default zero initialization is the initializer;
    ## in C use SHM_GSET_GENERATION_PUBLISHER_INIT or a static object. Keep its
    ## address stable until close completes. Never copy or reinitialize it
    ## while bound. It contains process-local pointers, never segment metadata.
    binding: uint64
    generation, alive, word: ptr uint64
    captured: uint64

  PublisherPrepareStatus* = enum
    ppsUnavailable, ppsReady, ppsInvalidWord, ppsUnsupportedAtomics,
    ppsStorageInUse, ppsInvalidState

  GenerationPublishStatus* {.size: sizeof(cint).} = enum
    gpsPublished, gpsAlreadyPublished, gpsUnavailable,
    gpsConsumerGone, gpsGenerationChanged, gpsInvalidState

  GenerationPublisherOwner*[K] = object
    ## Move-only private attachment to an existing anchor. Close/destruction
    ## require publication quiescence and disarm before deregistering/unmapping.
    ## After a private-address-space fork a recycling consumer must close the
    ## inherited owner and reopen before publishing. Child close preserves the
    ## parent's registration; inheritance does not register the child PID.
    attachment: ShmGSetT[K]
    storage: ptr PreparedGenerationPublisher
    preparation: PublisherPrepareStatus
    failure: AttachFailure

proc publisherAtomicsSupported(): cint {.cdecl, importc:
  "shm_gset_publisher_atomics_supported", header: publisherInternalHeader.}
proc publisherClaim(s: ptr PreparedGenerationPublisher): cint {.cdecl, importc:
  "shm_gset_publisher_claim", header: publisherInternalHeader.}
proc publisherArm(s: ptr PreparedGenerationPublisher;
  generation, alive, word: ptr uint64): cint {.cdecl, importc:
  "shm_gset_publisher_arm", header: publisherInternalHeader.}
proc publisherDisarm(s: ptr PreparedGenerationPublisher) {.cdecl, importc:
  "shm_gset_publisher_disarm", header: publisherInternalHeader.}
proc publisherRelease(s: ptr PreparedGenerationPublisher) {.cdecl, importc:
  "shm_gset_publisher_release", header: publisherInternalHeader.}

proc publishPreparedGeneration*(storage: ptr PreparedGenerationPublisher):
    GenerationPublishStatus {.cdecl, raises: [], importc:
      "shm_gset_publish_prepared_generation", header: publisherHeader.}
  ## Lock-free, concurrent and reentrant publication using only prepared memory.
  ## No TLS, errno, allocation, I/O or Nim runtime calls. An unbound/disarmed
  ## POD returns gpsUnavailable. Calling through freed POD storage is invalid.

proc close*[K](owner: var GenerationPublisherOwner[K]) =
  ## Idempotent. Requires publication quiescence. Storage remains claimed until
  ## the mapping and registration are released, including on partial-open error.
  if owner.storage != nil:
    publisherDisarm(owner.storage)
    owner.attachment.detach()
    publisherRelease(owner.storage)
    owner.storage = nil

proc `=destroy`*[K](owner: var GenerationPublisherOwner[K]) =
  owner.close()
  `=destroy`(owner.attachment)

proc `=copy`*[K](dest: var GenerationPublisherOwner[K];
    source: GenerationPublisherOwner[K]) {.error:
      "GenerationPublisherOwner is move-only; use move(owner)".}

proc available*[K](owner: GenerationPublisherOwner[K]): bool =
  owner.storage != nil and owner.preparation == ppsReady

proc prepareStatus*[K](owner: GenerationPublisherOwner[K]): PublisherPrepareStatus =
  owner.preparation

proc attachFailure*[K](owner: GenerationPublisherOwner[K]): AttachFailure =
  owner.failure

when shmGSetSupported and defined(shmGSetScheduleHooks):
  proc generationPublisherMappedAtForTest*[K](owner: GenerationPublisherOwner[K];
      expected: pointer): bool =
    ## Test-only comparison, without exporting the owner's mapped address.
    owner.available and cast[pointer](owner.attachment.shards[0].base) == expected

proc openGenerationPublisher*[K](path0: string; policy: typedesc[K]; word: int;
    storage: var PreparedGenerationPublisher): GenerationPublisherOwner[K] =
  ## Attach/register independently of ordinary producers, then arm one policy
  ## word. Failure releases partial resources. Racing opens of a live POD fail
  ## without changing its first owner. The POD must already be initialized.
  mixin extraControlWords
  if publisherAtomicsSupported() == 0:
    result.preparation = ppsUnsupportedAtomics
    return
  if cast[uint](addr storage) mod uint(sizeof(uint64)) != 0:
    result.preparation = ppsInvalidState
    return
  if publisherClaim(addr storage) == 0:
    result.preparation = ppsStorageInUse
    return
  result.storage = addr storage
  try:
    if word < 0 or word >= extraControlWords(K):
      result.preparation = ppsInvalidWord
      return
    result.attachment = attachSetT(path0, K)
    result.failure = result.attachment.attachFailure
    if not result.attachment.available: return
    when shmGSetSupported:
      let b = result.attachment.shards[0].base
      if publisherArm(addr storage, atField(b, ShOffGeneration, uint64),
          atField(b, ShOffConsumerAlive, uint64),
          atField(b, ShOffExtraControl + word * 8, uint64)) == 0:
        result.preparation = ppsInvalidState
        return
      result.preparation = ppsReady
  finally:
    if result.preparation != ppsReady: result.close()
