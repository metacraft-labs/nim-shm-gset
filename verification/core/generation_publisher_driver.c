/* Exercises the shipped compilation unit, not a transcription. Each CASE is a
 * finite weak-memory workload for GenMC and also an executable native oracle.
 * No mapping is simulated here: Nim tests cover mappings/process lifetimes;
 * these prepared words isolate the actual C atomic publication operations. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#ifndef CASE
#define CASE 0
#endif
#if CASE == 4 || CASE == 5
#define SHM_GSET_PUBLISHER_TEST_HOOKS
#endif
#ifndef SHM_GSET_PUBLISHER_SOURCE
#define SHM_GSET_PUBLISHER_SOURCE "../../src/shm_gset/generation_publisher.c"
#endif
#include SHM_GSET_PUBLISHER_SOURCE

static uint64_t generation = 1, alive = 1, word, payload;
static shm_gset_prepared_generation_publisher first = SHM_GSET_GENERATION_PUBLISHER_INIT;
static shm_gset_prepared_generation_publisher second = SHM_GSET_GENERATION_PUBLISHER_INIT;
static int outcomes[2];

static void prepare(shm_gset_prepared_generation_publisher *s) {
    assert(shm_gset_publisher_atomics_supported());
    assert(shm_gset_publisher_claim(s));
    assert(shm_gset_publisher_arm(s, &generation, &alive, &word));
}

#if CASE == 4 || CASE == 5
static void forced_reset(int point) {
    if (point != 1) return;
    shm_gset_publisher_test_hook = 0;
    __atomic_store_n(&generation, 2, __ATOMIC_RELEASE);
#if CASE == 5
    prepare(&second);
    assert(shm_gset_publish_prepared_generation(&second) == SHM_GSET_PUBLISHED);
#endif
}
#endif

static void *left(void *unused) {
    (void)unused;
#if CASE == 0
    __atomic_store_n(&payload, 42, __ATOMIC_RELAXED);
    assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_PUBLISHED);
#elif CASE == 1 || CASE == 2
    outcomes[0] = shm_gset_publish_prepared_generation(&first);
#elif CASE == 3
    outcomes[0] = shm_gset_publisher_claim(&first);
    if (outcomes[0]) assert(shm_gset_publisher_arm(&first, &generation, &alive, &word));
#elif CASE == 6
    prepare(&first);
#endif
    return 0;
}

static void *right(void *unused) {
    (void)unused;
#if CASE == 0
    if (__atomic_load_n(&word, __ATOMIC_ACQUIRE) == 1)
        assert(__atomic_load_n(&payload, __ATOMIC_RELAXED) == 42); /* ORACLE: published_payload_visible */
#elif CASE == 1
    outcomes[1] = shm_gset_publish_prepared_generation(&first);
#elif CASE == 2
    /* Deliberately bypass registration to test monotonicity under forced reset.
     * Production attachment owns the registry/seal exclusion, covered by the
     * existing reset model and real raw/typed-host refusal tests. */
    __atomic_store_n(&alive, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&generation, 2, __ATOMIC_RELEASE);
    prepare(&second);
    outcomes[1] = shm_gset_publish_prepared_generation(&second);
    assert(outcomes[1] == SHM_GSET_PUBLISHED);
#elif CASE == 3
    outcomes[1] = shm_gset_publisher_claim(&first);
    if (outcomes[1]) assert(shm_gset_publisher_arm(&first, &generation, &alive, &word));
#elif CASE == 6
    outcomes[1] = shm_gset_publish_prepared_generation(&first);
    assert(outcomes[1] == SHM_GSET_UNAVAILABLE || outcomes[1] == SHM_GSET_PUBLISHED);
#endif
    return 0;
}

int main(void) {
#if CASE != 3 && CASE != 6
    prepare(&first);
#endif
#if CASE == 4 || CASE == 5
    shm_gset_publisher_test_hook = forced_reset;
    assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_GENERATION_CHANGED); /* ORACLE: forced_reset_reports_stale */
#if CASE == 4
    assert(word == 1); /* a delayed old store remains old, never current */
    prepare(&second);
    assert(shm_gset_publish_prepared_generation(&second) == SHM_GSET_PUBLISHED);
#else
    assert(word == 2); /* the delayed old CAS cannot erase the newer mark */
#endif
    assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_GENERATION_CHANGED);
#else
    pthread_t a, b;
    assert(!pthread_create(&a, 0, left, 0));
    assert(!pthread_create(&b, 0, right, 0));
    assert(!pthread_join(a, 0));
    assert(!pthread_join(b, 0));
#endif
#if CASE == 0
    assert(__atomic_load_n(&word, __ATOMIC_ACQUIRE) == 1);
#elif CASE == 1
    assert((outcomes[0] == SHM_GSET_PUBLISHED && outcomes[1] == SHM_GSET_ALREADY_PUBLISHED) || /* ORACLE: exactly_one_publication */
        (outcomes[1] == SHM_GSET_PUBLISHED && outcomes[0] == SHM_GSET_ALREADY_PUBLISHED));
    assert(word == 1);
#elif CASE == 2
    assert(word == 2); /* ORACLE: newer_mark_preserved; the old publisher must never erase it */
#elif CASE == 3
    assert(outcomes[0] + outcomes[1] == 1); /* ORACLE: exclusive_storage_claim */
    assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_PUBLISHED);
#elif CASE == 6
    if (outcomes[1] == SHM_GSET_UNAVAILABLE)
        assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_PUBLISHED);
    else
        assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_ALREADY_PUBLISHED);
    assert(word == 1);
#endif
    shm_gset_publisher_disarm(&first);
    assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_UNAVAILABLE); /* ORACLE: closed_storage_unavailable */
    shm_gset_publisher_release(&first);
    assert(shm_gset_publisher_claim(&first));
    shm_gset_publisher_release(&first);
    return 0;
}
