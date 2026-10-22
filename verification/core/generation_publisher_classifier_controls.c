/* Real failing programs used to test the diagnostic classifier. Cases 0/1
 * perform no publication. Cases 2/3 first publish successfully, then fail at
 * the same unrelated assertion/race: publication elsewhere in a trace must
 * not make either reported error acceptable as a mutation's intended oracle. */
#include <assert.h>
#include <pthread.h>
#ifndef SHM_GSET_PUBLISHER_SOURCE
#define SHM_GSET_PUBLISHER_SOURCE "../../src/shm_gset/generation_publisher.c"
#endif
#include SHM_GSET_PUBLISHER_SOURCE

#ifndef CLASSIFIER_CASE
#error CLASSIFIER_CASE must select a real negative control
#endif

static volatile int unrelated;
static uint64_t generation = 1, alive = 1, word;
static shm_gset_prepared_generation_publisher first = SHM_GSET_GENERATION_PUBLISHER_INIT;
static void *worker(void *arg) {
    unrelated = 1; /* CLASSIFIER_CONTROL: unrelated_race */
    return arg;
}

int main(void) {
#if CLASSIFIER_CASE >= 2
    assert(shm_gset_publisher_claim(&first));
    assert(shm_gset_publisher_arm(&first, &generation, &alive, &word));
    assert(shm_gset_publish_prepared_generation(&first) == SHM_GSET_PUBLISHED);
    assert(word == 1);
#endif
#if CLASSIFIER_CASE % 2 == 0
    assert(0 && "unrelated classifier control"); /* CLASSIFIER_CONTROL: unrelated_assertion */
#else
    pthread_t a, b;
    assert(!pthread_create(&a, 0, worker, 0));
    assert(!pthread_create(&b, 0, worker, 0));
    assert(!pthread_join(a, 0));
    assert(!pthread_join(b, 0));
#endif
    return 0;
}
