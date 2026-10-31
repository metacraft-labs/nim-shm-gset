#ifndef SHM_GSET_GENERATION_PUBLISHER_H
#define SHM_GSET_GENERATION_PUBLISHER_H

#include <stdint.h>

/* This source unit is linked into each consuming image. Bind its calls within
 * that image, avoiding ELF interposition and first-call lazy PLT resolution. */
#if defined(__GNUC__) && !defined(_WIN32)
#define SHM_GSET_PUBLISHER_LOCAL __attribute__((visibility("hidden")))
#else
#define SHM_GSET_PUBLISHER_LOCAL
#endif

/* Process-local storage, never put in the shared segment. All fields are
 * library-private. Initialize once, before first open, using the initializer
 * below (or static zero initialization). Never copy, move, or reinitialize live
 * storage. Its address must remain stable until its owner has closed. */
typedef struct shm_gset_prepared_generation_publisher {
    uint64_t binding;
    uint64_t *generation;
    uint64_t *alive;
    uint64_t *word;
    uint64_t captured;
} shm_gset_prepared_generation_publisher;

#define SHM_GSET_GENERATION_PUBLISHER_INIT {0, 0, 0, 0, 0}

typedef enum shm_gset_generation_publish_status {
    SHM_GSET_PUBLISHED,
    SHM_GSET_ALREADY_PUBLISHED,
    SHM_GSET_UNAVAILABLE,
    SHM_GSET_CONSUMER_GONE,
    SHM_GSET_GENERATION_CHANGED,
    SHM_GSET_INVALID_STATE
} shm_gset_generation_publish_status;

/* Concurrent/reentrant publication is supported. Open/close require publication
 * quiescence: this is not a concurrent-unmap protocol. The call touches only
 * prepared memory, with lock-free atomic operations; it has no runtime calls.
 * Success records the captured generation as of the final generation acquire.
 * A reset observed during publication returns GENERATION_CHANGED; a delayed
 * old mark can remain, but can neither claim nor erase a newer generation. */
SHM_GSET_PUBLISHER_LOCAL shm_gset_generation_publish_status shm_gset_publish_prepared_generation(
    const shm_gset_prepared_generation_publisher *storage);

#endif
