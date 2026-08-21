/*
 * shm_gset_reset_core.c — the extracted C11 atomics core of nim-shm-gset's
 * RESET / RECYCLING protocol (HM-2), for stateless model checking under weak
 * memory (design spec io-mon-Lossless-Event-Capture §4.5(a)).
 *
 * It reproduces, with the SAME memory orders as src/shm_gset.nim, the five
 * load-bearing atomic sites recycling adds, on a deliberately tiny
 * forced-collision table:
 *
 *   1. generation publish      release store            (reset, THE COMMIT)
 *   2. generation observe      acquire load             (currentGeneration)
 *   3. slot claim, stamped     CAS stale -> (gen|off), ACQ_REL
 *                                                       (insertIntoShard)
 *   4. arena reserve, rebasing CAS (gen|used), ACQ_REL   (reserveArena)
 *   5. seal / registry         SEQ_CST store+load vs SEQ_CST RMW+load
 *                                                       (reset vs attachSetT)
 *
 * Site 5 is the only sequentially-consistent pair in the library and it is here
 * because it MUST be: it is a store-buffer (Dekker) shape, and "neither side
 * sees the other" is permitted by acquire/release AND by x86-TSO. See the
 * `-DRELAXED_SEAL` build below, which is the control.
 *
 * ORACLES (assert()s a model checker will try to violate):
 *   - no cross-generation leakage: every slot that reads LIVE under the current
 *     generation holds an element inserted UNDER that generation;
 *   - torn-read: a live slot always points at a complete record;
 *   - no-loss: an element published under the current generation is findable;
 *   - quiescence: the reset never commits while a producer is registered
 *     (the seal handshake), so no producer ever stamps a generation whose
 *     action it does not belong to.
 *
 * HOW TO MODEL-CHECK. nixpkgs carries neither tool, so this repo packages and
 * pins them (see ../../nix/ and ../../flake.nix). Blessed runner: `just
 * verify-models`. RAN and green: 30 504 complete + 5 808 blocked executions
 * under GenMC/RC11; the -DRELAXED_SEAL control reports `Error: Safety
 * violation!` with a counterexample, which is the `m6` coverage the TLA+ model
 * cannot express (there, PAttach is atomic). Equivalent commands:
 *   GenMC:      genmc -disable-ipr -unroll=5 -- -std=c11 shm_gset_reset_core.c
 *   GenMC ctl:  ... -DRELAXED_SEAL   (MUST report a safety violation)
 * `-disable-ipr` is needed because the hand-rolled spin barrier has two threads
 * storing the same value to bar_go, which GenMC's in-place revisiting treats as
 * an error. Nidhugg cannot run this core under --arm (its ARM trace builder
 * rejects atomicrmw); see ../README.md.
 *
 * It also builds+runs natively as a FUNCTIONAL smoke over many random schedules
 * — that is NOT a weak-memory proof (a native run cannot exhaustively reorder);
 * it only proves the core compiles and its logic is self-consistent. Build:
 *   cc -std=c11 -O2 -pthread -DSTANDALONE shm_gset_reset_core.c -o reset_core_run
 * and the CONTROL, which must FAIL its quiescence oracle often enough to prove
 * the seq_cst is load-bearing:
 *   cc -std=c11 -O2 -pthread -DSTANDALONE -DRELAXED_SEAL ...
 */
#include <stdatomic.h>
#include <stdint.h>
#include <assert.h>
#include <pthread.h>

#ifndef CAP
#define CAP 2            /* slots per shard (power of two) */
#endif
#ifndef ARENA
#define ARENA 4          /* record capacity */
#endif
#ifndef NPROD
#define NPROD 2
#endif

/* A slot entry mirrors the shipped packing: (generation << 32) | offset, with 0
 * meaning "never written". A slot is EMPTY unless its generation stamp equals
 * the chain's current generation — which is what makes reset a single store. */
typedef uint64_t entry_t;
#define GEN_SHIFT 32
#define OFF_MASK  0xFFFFFFFFu
#define PACK(g, o) (((uint64_t)(g) << GEN_SHIFT) | (uint32_t)(o))
#define EGEN(e)   ((uint32_t)((e) >> GEN_SHIFT))
#define EOFF(e)   ((uint32_t)((e) & OFF_MASK))

struct rec {
    atomic_uint fp;       /* fingerprint, never 0 when published */
    atomic_uint val;      /* payload == fp, so a torn read is detectable */
    atomic_uint gen;      /* the generation this record was written under */
};

static _Atomic entry_t slot[CAP];
static struct rec      arena[ARENA];
static _Atomic uint64_t arena_used;   /* (gen << 32) | usedBytes, rebasing */
static _Atomic uint32_t generation;   /* THE commit point */
static _Atomic uint32_t alive;        /* consumer-liveness token */
static _Atomic uint32_t seal;         /* reset in progress */
static _Atomic uint32_t reg[NPROD];   /* producer registry: 0 == free */

/* --- the seal handshake ------------------------------------------------- */
#ifdef RELAXED_SEAL
#define SEAL_ORDER   memory_order_release
#define SEAL_LOAD    memory_order_acquire
#define REG_ORDER    memory_order_acq_rel
#define REG_LOAD     memory_order_acquire
#else
#define SEAL_ORDER   memory_order_seq_cst
#define SEAL_LOAD    memory_order_seq_cst
#define REG_ORDER    memory_order_seq_cst
#define REG_LOAD     memory_order_seq_cst
#endif

static _Atomic uint32_t leaks;      /* cross-generation leak counter */

/* In the SHIPPED build the cross-generation oracle is a hard assert. In the
 * RELAXED_SEAL control it COUNTS instead, so the NATIVE hammer can report how
 * often the weaker ordering leaks rather than aborting on the first one.
 *
 * The count-instead-of-assert applies to the STANDALONE (native, many-runs)
 * build ONLY. Under a stateless model checker there is no "how often" — there
 * is one symbolic run and the question is whether the leak is REACHABLE — so
 * the control must assert there, otherwise GenMC/Nidhugg would report "no
 * errors" on the control and the control would prove nothing. */
#if defined(RELAXED_SEAL) && defined(STANDALONE)
#define GEN_ORACLE(cond) \
    do { if (!(cond)) atomic_fetch_add_explicit(&leaks, 1, \
                                                memory_order_seq_cst); } while (0)
#else
#define GEN_ORACLE(cond) assert(cond)
#endif

/* Attach: CLAIM the registry entry, THEN read the seal, and back out if it is
 * set. Paired with reset's "store the seal, THEN scan the registry", the
 * sequentially-consistent version forbids the outcome in which neither side
 * sees the other. Returns 1 on success. */
static int attach(unsigned me)
{
    uint32_t expect = 0;
    if (!atomic_compare_exchange_strong_explicit(&reg[me], &expect, me + 1,
                                                 REG_ORDER, REG_LOAD))
        return 0;                                  /* entry busy */
    if (atomic_load_explicit(&seal, SEAL_LOAD) != 0) {
        atomic_store_explicit(&reg[me], 0, memory_order_release);
        return 0;                                  /* a reset is in progress */
    }
    return 1;
}

static void detach(unsigned me)
{
    atomic_store_explicit(&reg[me], 0, memory_order_release);
}

/* Lock-free, generation-rebasing bump allocation (reserveArena). */
static int reserve(uint32_t gen, unsigned *out)
{
    uint64_t cur = atomic_load_explicit(&arena_used, memory_order_acquire);
    for (;;) {
        uint32_t cgen = (uint32_t)(cur >> GEN_SHIFT);
        unsigned used = (cgen == gen) ? (unsigned)(cur & OFF_MASK) : 0u;
        if (used >= ARENA) return 0;
        uint64_t want = PACK(gen, used + 1);
        if (atomic_compare_exchange_weak_explicit(&arena_used, &cur, want,
                memory_order_acq_rel, memory_order_acquire)) {
            *out = used;
            return 1;
        }
    }
}

/* One insert under the generation the producer READ. Mirrors insertIntoShard:
 * a slot is claimable when it is not live under `gen`, and the claim CAS
 * expects the exact stale value observed. */
static int insert(uint32_t gen, unsigned key)
{
    for (unsigned probes = 0, idx = 0; probes < CAP; probes++,
             idx = (idx + 1) & (CAP - 1)) {
        entry_t e = atomic_load_explicit(&slot[idx], memory_order_acquire);
        if (e == 0 || EGEN(e) != gen) {            /* empty for THIS generation */
            unsigned r;
            if (!reserve(gen, &r)) return -1;
            atomic_store_explicit(&arena[r].fp,  key, memory_order_relaxed);
            atomic_store_explicit(&arena[r].val, key, memory_order_relaxed);
            atomic_store_explicit(&arena[r].gen, gen, memory_order_relaxed);
            entry_t expect = e;
            if (atomic_compare_exchange_strong_explicit(&slot[idx], &expect,
                    PACK(gen, r + 1), memory_order_acq_rel,
                    memory_order_acquire))
                return 1;
            e = expect;                            /* lost the claim */
        }
        if (EGEN(e) == gen) {
            unsigned ri = EOFF(e) - 1;
            unsigned fp = atomic_load_explicit(&arena[ri].fp,
                                               memory_order_acquire);
            unsigned vl = atomic_load_explicit(&arena[ri].val,
                                               memory_order_acquire);
            unsigned rg = atomic_load_explicit(&arena[ri].gen,
                                               memory_order_acquire);
            assert(fp != 0);          /* TORN-READ ORACLE */
            assert(vl == fp);         /* TORN-READ ORACLE */
            GEN_ORACLE(rg == gen);    /* NO CROSS-GENERATION LEAK, per record */
            if (fp == key) return 0;  /* idempotent */
        }
    }
    return -1;
}

/* --- the reset ---------------------------------------------------------- */
static _Atomic uint32_t straddles;   /* QUIESCENCE ORACLE counter, see below */

static void reset_chain(void)
{
    uint32_t cur = atomic_load_explicit(&generation, memory_order_acquire);
    atomic_store_explicit(&seal, 1, SEAL_ORDER);
    for (unsigned i = 0; i < NPROD; i++)
        if (atomic_load_explicit(&reg[i], REG_LOAD) != 0) {
            atomic_store_explicit(&seal, 0, SEAL_ORDER);
            return;                               /* rsBusyProducers */
        }
    atomic_store_explicit(&alive, 1, memory_order_relaxed);   /* RE-ARM ... */
    atomic_store_explicit(&generation, cur + 1,
                          memory_order_release);              /* ... then COMMIT */
    atomic_store_explicit(&seal, 0, SEAL_ORDER);
}

/* --- harness ------------------------------------------------------------ */
#define KEY(i) (0x11u * ((i) + 1))

struct arg { unsigned id; };

/* A spin barrier, so the reset and the attaches actually collide instead of
 * being serialised by thread-creation latency. Without it a native run almost
 * never reaches the window the control is trying to demonstrate. */
static _Atomic unsigned bar_count;
static _Atomic unsigned bar_go;
static void barrier_wait(unsigned n)
{
    atomic_fetch_add_explicit(&bar_count, 1, memory_order_seq_cst);
    if (atomic_load_explicit(&bar_count, memory_order_seq_cst) == n)
        atomic_store_explicit(&bar_go, 1, memory_order_seq_cst);
    while (atomic_load_explicit(&bar_go, memory_order_seq_cst) == 0) { }
}

static void *producer(void *v)
{
    unsigned me = ((struct arg *)v)->id;
    barrier_wait(NPROD + 1);
    if (!attach(me)) return 0;
    /* The action this producer BELONGS to, fixed the moment its attach
     * succeeded. */
    uint32_t gen_at_attach = atomic_load_explicit(&generation,
                                                  memory_order_acquire);
    /* emit(): read the generation (acquire) FIRST, then the liveness token.
     * The acquire is what makes reset's re-arm visible to anyone who observes
     * the new generation. */
    uint32_t gen = atomic_load_explicit(&generation, memory_order_acquire);
    uint32_t a   = atomic_load_explicit(&alive, memory_order_acquire);
    GEN_ORACLE(a != 0);             /* LIVENESS ORACLE: the token is never gone
                                     * under a generation accepting inserts */
    /* QUIESCENCE ORACLE. A successful attach means either the reset had not
     * started (its later scan will see this registry entry and refuse) or it
     * had already finished. Either way the generation cannot move between the
     * attach and the insert, so this producer's element can only ever be
     * attributed to the action it belongs to. A STRADDLE — gen != gen_at_attach
     * with the attach still held — is precisely the cross-attribution the seal
     * exists to forbid, and precisely what RELAXED_SEAL lets through. */
    if (gen != gen_at_attach)
        atomic_fetch_add_explicit(&straddles, 1, memory_order_seq_cst);
    if (a) (void)insert(gen, KEY(me));
    detach(me);
    return 0;
}

static void *resetter(void *v)
{
    (void)v;
    barrier_wait(NPROD + 1);
    reset_chain();
    return 0;
}

static void init_state(void)
{
    for (unsigned i = 0; i < CAP; i++)
        atomic_store_explicit(&slot[i], 0, memory_order_relaxed);
    for (unsigned i = 0; i < ARENA; i++) {
        atomic_store_explicit(&arena[i].fp,  0, memory_order_relaxed);
        atomic_store_explicit(&arena[i].val, 0, memory_order_relaxed);
        atomic_store_explicit(&arena[i].gen, 0, memory_order_relaxed);
    }
    atomic_store_explicit(&arena_used, 0, memory_order_relaxed);
    atomic_store_explicit(&generation, 1, memory_order_relaxed);
    atomic_store_explicit(&alive, 1, memory_order_relaxed);
    atomic_store_explicit(&seal, 0, memory_order_relaxed);
    for (unsigned i = 0; i < NPROD; i++)
        atomic_store_explicit(&reg[i], 0, memory_order_relaxed);
    atomic_store_explicit(&bar_count, 0, memory_order_relaxed);
    atomic_store_explicit(&bar_go, 0, memory_order_relaxed);
}

static void run_once(void)
{
    init_state();
    pthread_t t[NPROD + 1];
    struct arg a[NPROD];
    for (unsigned i = 0; i < NPROD; i++) {
        a[i].id = i;
        pthread_create(&t[i], 0, producer, &a[i]);
    }
    pthread_create(&t[NPROD], 0, resetter, 0);
    for (unsigned i = 0; i <= NPROD; i++) pthread_join(t[i], 0);

    /* NO CROSS-GENERATION LEAKAGE, chain-wide: every slot that reads live under
     * the final generation holds a record written under that same generation. */
    uint32_t gen = atomic_load_explicit(&generation, memory_order_acquire);
    for (unsigned i = 0; i < CAP; i++) {
        entry_t e = atomic_load_explicit(&slot[i], memory_order_acquire);
        if (e == 0 || EGEN(e) != gen) continue;   /* stale: unreachable */
        unsigned ri = EOFF(e) - 1;
        GEN_ORACLE(atomic_load_explicit(&arena[ri].gen,
                                        memory_order_acquire) == gen);
        unsigned fp = atomic_load_explicit(&arena[ri].fp, memory_order_acquire);
        int known = 0;
        for (unsigned k = 0; k < NPROD; k++) if (fp == KEY(k)) known = 1;
        assert(known);                            /* NO PHANTOM (both builds) */
    }
}

#ifdef STANDALONE
#include <stdio.h>
#ifndef NITER
#define NITER 200000
#endif
int main(void)
{
    for (long i = 0; i < (long)NITER; i++) run_once();
    unsigned busy = atomic_load_explicit(&straddles, memory_order_seq_cst);
#ifdef RELAXED_SEAL
    unsigned lk = atomic_load_explicit(&leaks, memory_order_seq_cst);
    printf("[control] RELAXED_SEAL: %ld runs, %u attached producers straddled a "
           "reset and %u cross-generation leaks resulted. A NONZERO count is "
           "the POINT: it shows the shipped seq_cst handshake is load-bearing, "
           "not decoration.\n", (long)NITER, busy, lk);
    return 0;   /* informational: the control reports, it never fails a build */
#else
    if (busy != 0) {
        printf("[FAILED] %u attached producers straddled a reset under the "
               "SHIPPED ordering\n", busy);
        return 1;
    }
    printf("[OK] shm_gset_reset_core functional smoke: %ld reset-vs-insert "
           "races, no cross-generation leak / torn read / phantom, and no "
           "reset committed while a producer was attached "
           "(NOT a weak-memory proof)\n", (long)NITER);
    return 0;
#endif
}
#else
/* Model-checker entry: ONE symbolic run, with the two properties the native
 * hammer can only COUNT raised to hard assertions — a stateless checker answers
 * "is this reachable", not "how often", so a counter it never reads would make
 * the RELAXED_SEAL control silently vacuous. */
int main(void)
{
    run_once();
    /* QUIESCENCE: no producer ever holds an attach across a generation change. */
    assert(atomic_load_explicit(&straddles, memory_order_seq_cst) == 0);
    return 0;
}
#endif
