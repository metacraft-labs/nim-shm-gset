/*
 * CDSChecker port of the seal / producer-registry handshake (`reset` vs
 * `attachSetT`), design spec §4.5(a), HM-2. Third independent tool over the
 * same property that ../litmus/reset-seal-vs-register.litmus states to herd7
 * and that ../core/shm_gset_reset_core.c states to GenMC.
 *
 * WHY THIS IS A PORT AND NOT THE CORE ITSELF. CDSChecker is a shared library
 * that REPLACES the C11 atomics and the thread API: a checked program must use
 * ITS <threads.h> (thrd_create / thrd_join, no return-value argument) and ITS
 * <stdatomic.h>, and must name its entry point user_main(). ../core/*.c use
 * POSIX threads and the system <stdatomic.h> — which is deliberate, since they
 * are meant to be the same compilation unit that ships — so they run unmodified
 * under GenMC and Nidhugg but cannot be handed to CDSChecker as they stand.
 * This file is therefore the handshake ALONE, transcribed, not the whole core.
 *
 * Build and run (the tools come from this repo's pinned flake):
 *   just verify-cdschecker
 *
 * SHIPPED build   -> no buggy executions. RUNS, and is green.
 * -DRELAXED_SEAL  -> would have to report a buggy execution. It does NOT run:
 *                    upstream CDSChecker ABORTS on this program inside its own
 *                    snapshotting allocator. The build is kept here because the
 *                    control is the interesting half and the abort should be
 *                    re-tested against future CDSChecker releases, but the
 *                    runner skips it and names the four artifacts that do cover
 *                    the property — see run-cdschecker.sh.
 */
#include <stdlib.h>
#include <stdio.h>
#include <threads.h>
#include <stdatomic.h>

#include "model-assert.h"

#ifdef RELAXED_SEAL
#define SEAL_STORE memory_order_release
#define SEAL_LOAD  memory_order_acquire
#define REG_STORE  memory_order_release
#define REG_LOAD   memory_order_acquire
#else
#define SEAL_STORE memory_order_seq_cst
#define SEAL_LOAD  memory_order_seq_cst
#define REG_STORE  memory_order_seq_cst
#define REG_LOAD   memory_order_seq_cst
#endif

static atomic_int seal;      /* reset in progress */
static atomic_int reg;       /* producer registry entry: 0 == free */

static atomic_int reset_saw_producer;
static atomic_int producer_saw_seal;

/* reset(): store the seal, THEN scan the registry. */
static void resetter(void *unused)
{
    atomic_store_explicit(&seal, 1, SEAL_STORE);
    int r = atomic_load_explicit(&reg, REG_LOAD);
    atomic_store_explicit(&reset_saw_producer, r != 0, memory_order_seq_cst);
}

/* attachSetT(): claim the registry entry, THEN read the seal and back out. */
static void producer(void *unused)
{
    atomic_store_explicit(&reg, 1, REG_STORE);
    int s = atomic_load_explicit(&seal, SEAL_LOAD);
    atomic_store_explicit(&producer_saw_seal, s != 0, memory_order_seq_cst);
}

int user_main(int argc, char **argv)
{
    thrd_t a, b;

    atomic_init(&seal, 0);
    atomic_init(&reg, 0);
    atomic_init(&reset_saw_producer, 0);
    atomic_init(&producer_saw_seal, 0);

    thrd_create(&a, (thrd_start_t)&resetter, NULL);
    thrd_create(&b, (thrd_start_t)&producer, NULL);
    thrd_join(a);
    thrd_join(b);

    /* The dangerous outcome is the one where NEITHER side sees the other:
     * reset concludes the chain is quiescent while the producer concludes it
     * attached cleanly, and that producer's element then lands in the NEXT
     * action's dependency set. */
    MODEL_ASSERT(atomic_load_explicit(&reset_saw_producer, memory_order_seq_cst) ||
                 atomic_load_explicit(&producer_saw_seal, memory_order_seq_cst));
    return 0;
}
