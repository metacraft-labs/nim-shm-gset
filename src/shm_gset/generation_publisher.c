#include "generation_publisher_internal.h"
#include <stddef.h>

/* Never lower a supposedly lock-free publication into a libatomic call. The
 * unsupported arm contains no atomic builtin at all. uint64_t is the only
 * atomic width: binding and every shared header word use the same width. */
#if defined(__GNUC__) && __GCC_ATOMIC_LLONG_LOCK_FREE == 2 && \
    __GCC_ATOMIC_LONG_LOCK_FREE == 2
#define SHM_GSET_PUBLISHER_LOCK_FREE 1
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
    "generation publication requires always-lock-free uint64 atomics");
#else
#define SHM_GSET_PUBLISHER_LOCK_FREE 0
#endif

enum { UNBOUND, PREPARING, ARMED };

#ifdef SHM_GSET_PUBLISHER_TEST_HOOKS
/* Deterministic boundary probes, compiled out of the shipped unit. */
void (*shm_gset_publisher_test_hook)(int);
#define TEST_HOOK(point) do { \
    if (shm_gset_publisher_test_hook) shm_gset_publisher_test_hook(point); \
} while (0)
#else
#define TEST_HOOK(point) ((void)0)
#endif

int shm_gset_publisher_atomics_supported(void) {
    return SHM_GSET_PUBLISHER_LOCK_FREE;
}

int shm_gset_publisher_claim(shm_gset_prepared_generation_publisher *s) {
#if SHM_GSET_PUBLISHER_LOCK_FREE
    if (!s || (uintptr_t)s % sizeof(uint64_t)) return 0;
    uint64_t expected = UNBOUND;
    int claimed = __atomic_compare_exchange_n(&s->binding, &expected, PREPARING, 0,
        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    if (claimed) TEST_HOOK(0);
    return claimed;
#else
    (void)s;
    return 0;
#endif
}

int shm_gset_publisher_arm(shm_gset_prepared_generation_publisher *s,
    uint64_t *generation, uint64_t *alive, uint64_t *word) {
#if SHM_GSET_PUBLISHER_LOCK_FREE
    if (!generation || !alive || !word ||
        (uintptr_t)generation % sizeof(uint64_t) ||
        (uintptr_t)alive % sizeof(uint64_t) ||
        (uintptr_t)word % sizeof(uint64_t)) return 0;
    uint64_t captured = __atomic_load_n(generation, __ATOMIC_ACQUIRE);
    if (!captured || captured > UINT32_MAX) return 0;
    s->generation = generation;
    s->alive = alive;
    s->word = word;
    s->captured = captured;
    /* Only the winner of claim writes these fields. Losing/racing opens do
     * not even inspect them. Publication acquires this initialization. */
    __atomic_store_n(&s->binding, ARMED, __ATOMIC_RELEASE);
    return 1;
#else
    (void)s; (void)generation; (void)alive; (void)word;
    return 0;
#endif
}

void shm_gset_publisher_disarm(shm_gset_prepared_generation_publisher *s) {
#if SHM_GSET_PUBLISHER_LOCK_FREE
    /* Keep PREPARING until deregistration/unmapping finishes: a racing open
     * must not acquire this storage while the old owner is still closing. */
    __atomic_store_n(&s->binding, PREPARING, __ATOMIC_RELEASE);
    TEST_HOOK(2);
#else
    (void)s;
#endif
}

void shm_gset_publisher_release(shm_gset_prepared_generation_publisher *s) {
#if SHM_GSET_PUBLISHER_LOCK_FREE
    s->generation = s->alive = s->word = NULL;
    s->captured = 0;
    __atomic_store_n(&s->binding, UNBOUND, __ATOMIC_RELEASE);
#else
    (void)s;
#endif
}

shm_gset_generation_publish_status shm_gset_publish_prepared_generation(
    const shm_gset_prepared_generation_publisher *s) {
#if SHM_GSET_PUBLISHER_LOCK_FREE
    if (!s || __atomic_load_n(&s->binding, __ATOMIC_ACQUIRE) != ARMED)
        return SHM_GSET_UNAVAILABLE;
    const uint64_t g = s->captured;
    /* Generation must precede liveness, matching the reset re-arm protocol. */
    const uint64_t current = __atomic_load_n(s->generation, __ATOMIC_ACQUIRE);
    if (!current || current > UINT32_MAX) return SHM_GSET_INVALID_STATE;
    if (current != g) return SHM_GSET_GENERATION_CHANGED;
    if (!__atomic_load_n(s->alive, __ATOMIC_ACQUIRE)) return SHM_GSET_CONSUMER_GONE;
    uint64_t seen = __atomic_load_n(s->word, __ATOMIC_ACQUIRE);
    for (;;) {
        if (seen >= g) {
            if (__atomic_load_n(s->generation, __ATOMIC_ACQUIRE) != g)
                return SHM_GSET_GENERATION_CHANGED;
            return seen == g ? SHM_GSET_ALREADY_PUBLISHED : SHM_GSET_INVALID_STATE;
        }
        /* A delayed old publisher can never lower a newer mark. Registered
         * owners prevent reset in production; this remains monotonic even
         * if a test forces reset between the generation read and this CAS. */
        TEST_HOOK(1);
        if (__atomic_compare_exchange_n(s->word, &seen, g, 0,
            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            /* Normally redundant: the registration forbids reset. A forced
             * reset can leave an old mark, which the new generation ignores.
             * Report that race as stale when our final observation sees it;
             * success is for g at this observation, never for a future run. */
            if (__atomic_load_n(s->generation, __ATOMIC_ACQUIRE) != g)
                return SHM_GSET_GENERATION_CHANGED;
            return SHM_GSET_PUBLISHED;
        }
    }
#else
    (void)s;
    return SHM_GSET_UNAVAILABLE;
#endif
}
