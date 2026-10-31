#ifndef SHM_GSET_GENERATION_PUBLISHER_INTERNAL_H
#define SHM_GSET_GENERATION_PUBLISHER_INTERNAL_H
#include "generation_publisher.h"

/* Safe-context machinery used only by the library owner. No consumer-supplied
 * pointers, offsets, or generations are part of the public publication API. */
SHM_GSET_PUBLISHER_LOCAL int shm_gset_publisher_atomics_supported(void);
SHM_GSET_PUBLISHER_LOCAL int shm_gset_publisher_claim(shm_gset_prepared_generation_publisher *storage);
SHM_GSET_PUBLISHER_LOCAL int shm_gset_publisher_arm(shm_gset_prepared_generation_publisher *storage,
    uint64_t *generation, uint64_t *alive, uint64_t *word);
SHM_GSET_PUBLISHER_LOCAL void shm_gset_publisher_disarm(shm_gset_prepared_generation_publisher *storage);
SHM_GSET_PUBLISHER_LOCAL void shm_gset_publisher_release(shm_gset_prepared_generation_publisher *storage);
#ifdef SHM_GSET_PUBLISHER_TEST_HOOKS
extern void (*shm_gset_publisher_test_hook)(int);
#endif
#endif
