/*
 * CDSChecker port of the slot-claim publish->follow pair (design spec §4.5(a)),
 * the message-passing shape shared by all seven of the library's publish pairs.
 * See seal-vs-register.c in this directory for why these are ports rather than
 * the shipped cores.
 *
 * Producer: write the arena record bytes, then publish the slot with a RELEASE
 * store. Reader: ACQUIRE-load the slot and, only if it is non-zero, follow it to
 * the record. `store_32`/`load_32` are CDSChecker's instrumentation for the
 * non-atomic accesses, so its data-race detector sees them.
 *
 * SHIPPED build    -> no buggy executions.
 * -DRELAXED_SLOT   -> the release/acquire is downgraded to relaxed; CDSChecker
 *                     MUST report the torn read. A clean run under the control
 *                     is a FAILURE of the control.
 */
#include <stdlib.h>
#include <stdio.h>
#include <threads.h>
#include <stdatomic.h>

#include "librace.h"
#include "model-assert.h"

#ifdef RELAXED_SLOT
#define SLOT_STORE memory_order_relaxed
#define SLOT_LOAD  memory_order_relaxed
#else
#define SLOT_STORE memory_order_release
#define SLOT_LOAD  memory_order_acquire
#endif

static atomic_int slot;   /* 0 == empty, else 1-based arena record index */
static int rec_fp;        /* the arena record's fingerprint word */

static void producer(void *unused)
{
    store_32(&rec_fp, 42);                                   /* record bytes */
    atomic_store_explicit(&slot, 1, SLOT_STORE);             /* publish offset */
}

static void reader(void *unused)
{
    int s = atomic_load_explicit(&slot, SLOT_LOAD);
    if (s == 1)
        MODEL_ASSERT(load_32(&rec_fp) == 42);                /* follow it */
}

int user_main(int argc, char **argv)
{
    thrd_t a, b;

    atomic_init(&slot, 0);
    store_32(&rec_fp, 0);

    thrd_create(&a, (thrd_start_t)&producer, NULL);
    thrd_create(&b, (thrd_start_t)&reader, NULL);
    thrd_join(a);
    thrd_join(b);
    return 0;
}
